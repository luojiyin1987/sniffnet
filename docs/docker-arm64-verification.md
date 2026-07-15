# Docker arm64 支持 — 验证过程记录

## 背景

Sniffnet 的 Docker 镜像 `ghcr.io/gyulyvgc/sniffnet` 仅构建 `linux/amd64` 平台。
虽然 CI 中 QEMU 和 Buildx 已配置，但 `platforms` 字段未包含 `linux/arm64`。

## 代码安全验证

### cfg 属性扫描（✅ 零 target_arch 依赖）

```
rg "target_arch|cfg.*arch|cfg.*target" src/ build.rs
```

结果：
- 仅存在 `target_os` 条件编译（`windows` / `macos` / `linux`）
- 无任何 `target_arch`（`aarch64` / `x86_64`）相关路径
- 代码在所有 CPU 架构上编译路径完全一致

涉及文件：

| 文件 | cfg 类型 |
|---|---|
| `src/main.rs:13,101` | `target_os = "linux"` |
| `src/gui/sniffer.rs:939-943` | `target_os = "windows"` / `"macos"` |
| `src/gui/pages/initial_page.rs:253,258` | `target_os = "windows"` |
| `src/gui/pages/overview_page.rs:324,326` | `target_os = "windows"` |
| `src/networking/types/program.rs:36,38` | `target_os = "windows"` / `"macos"` |
| `src/networking/types/capture_context.rs:246` | `target_os = "windows"` |
| `src/utils/check_updates.rs:80` | `target_os = "macos"` (test only) |
| `build.rs:25` | `target_os = "windows"` (图标资源) |

### build.rs 审查（✅ 通过）

`build.rs` 功能：
1. `set_icon()` — 仅 Windows 下编译图标资源
2. `build_services_phf()` — 从 `services.txt` 生成 `phf::Map`，纯数据处理

两者均与 CPU 架构无关。

### 等效构建验证（✅ 旁证）

项目已通过 `Cross.toml` 交叉编译 arm64 原生包：

```toml
# Cross.toml:19-26
[target.aarch64-unknown-linux-gnu]
pre-build = [
    "dpkg --add-architecture arm64",
    "apt update -y && apt install -y libpcap-dev:arm64 ...",
]
```

Docker 构建的本质就是相同代码 + `cargo build --release`。
如果 arm64 DEB/RPM/AppImage 能构建成功，Docker arm64 镜像也不会失败。

## 构建方案演进

### 方案 1: QEMU 模拟构建（❌ 太慢，已废弃）

原始方案：`ubuntu-latest` + QEMU 模拟 arm64，单 job 构建两个平台。

```yaml
# 原始 docker.yml
runs-on: ubuntu-latest
steps:
  - uses: docker/setup-qemu-action@v4    # QEMU 模拟 arm64
  - uses: docker/setup-buildx-action@v4
  - uses: docker/build-push-action@v7
    with:
      platforms: linux/amd64,linux/arm64  # arm64 通过 QEMU 模拟编译
```

问题：QEMU 模拟下 `cargo build --release` 极其缓慢（本地 600s 超时未完成，CI 预期 30-60 分钟）。

### 方案 2: 原生 ARM Runner（✅ 当前方案）

使用 GitHub Actions 原生 ARM runner `ubuntu-24.04-arm`，与 `ubuntu-24.04` 并行运行。

**Job 结构**（3 个 job）：

| Job | Runner | 作用 |
|-----|--------|------|
| `check-version` | `ubuntu-latest` | 提取 Cargo.toml 版本号 |
| `build` (matrix) | `ubuntu-24.04` / `ubuntu-24.04-arm` | 各自原生编译 + Docker 打包 |
| `merge-manifest` | `ubuntu-latest` | 合并多架构 manifest（`docker manifest`） |

**build job 内部步骤**：

```yaml
steps:
  - uses: actions/checkout@v6
  - uses: dtolnay/rust-toolchain@stable    # 安装 Rust
  - uses: Swatinem/rust-cache@v2           # 缓存 ~/.cargo + target/
  - run: sudo apt-get install ...          # 系统构建依赖
  - run: cargo build --release             # 原生编译（不在 Docker 内）
  - uses: docker/setup-buildx-action@v4
  - uses: docker/build-push-action@v7      # Docker 纯打包
    with:
      platforms: linux/${{ matrix.arch }}
      cache-from: type=gha                 # BuildKit apt 层缓存
      cache-to: type=gha,mode=max
```

### 编译位置演进

```
方案 1:  checkout → Docker(cargo build + 打包)  ← 容器内编译，arm64 靠 QEMU
方案 2:  checkout → runner 原生 cargo build → Docker(只打包)  ← 原生编译，各 runner 自编自跑
```

对应 Dockerfile 从多阶段（builder + runtime）精简为单阶段纯打包：

```diff
- FROM rust:1.88-slim AS builder
- RUN apt-get install ... libpcap-dev ...
- COPY . .
- RUN cargo build --release
+ FROM debian:bookworm-slim
+ RUN apt-get install ... libpcap0.8 ...    # 只装运行时依赖
+ COPY target/release/sniffnet /usr/local/bin/sniffnet
```

`.dockerignore` 只放行最终二进制：

```dockerignore
*
!target/
target/*
!target/release/
target/release/*
!target/release/sniffnet
```

### 缓存层

| 缓存 | 工具 | 缓存内容 | 失效条件 |
|------|------|----------|----------|
| Rust 依赖/编译 | `Swatinem/rust-cache@v2` | `~/.cargo` + `target/` | Cargo.lock 变更 |
| Docker apt 层 | `type=gha` (BuildKit) | `apt-get install` 层 | Dockerfile RUN 行变更 |

### cargo-chef 实验（❌ 已废弃）

尝试用 [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) 在 Docker 内做依赖预编译缓存。

```dockerfile
# 实验的 Dockerfile 结构
FROM rust:1.88-slim AS chef
RUN cargo install cargo-chef

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner recipe.json .
RUN cargo chef cook --release --recipe-path recipe.json   # 编译依赖（可缓存）
COPY . .
RUN cargo build --release                                  # 只编译源码
```

结果：首次构建从 8 分钟上升到 11 分钟（+37%）。

原因：
- `cargo install cargo-chef` 额外编译时间
- `cargo-chef` 最新版依赖 `cargo-platform@0.3.3` 要求 rustc ≥1.91，与 Docker 基础镜像 `rust:1.88` 冲突（`--locked` 可解决但无实质帮助）
- 多阶段 COPY 增加层数
- 无跨构建持久化缓存（如 `--mount=type=cache`），纯 Docker layer cache 场景下得不偿失

结论：`cargo-chef` 适合有持久化 BuildKit cache mount 的 CI，纯 GitHub Actions runner + Docker 场景是负优化。

## 最终工作流文件

```yaml
# .github/workflows/docker.yml （测试阶段，部分功能注释）
name: Docker

on:
  workflow_dispatch:
  push:
    branches: [feat/docker-arm64-support]  # 测试用，正式合并后移除

jobs:
  check-version:
    name: Check version
    runs-on: ubuntu-latest
    # ... 提取 Cargo.toml 版本号

  build:
    name: Build ${{ matrix.platform }}
    needs: check-version
    runs-on: ${{ matrix.runner }}
    strategy:
      matrix:
        include:
          - runner: ubuntu-24.04
            arch: amd64
          - runner: ubuntu-24.04-arm
            arch: arm64
    steps:
      - checkout
      - dtolnay/rust-toolchain@stable
      - Swatinem/rust-cache@v2
      - apt-get install build deps
      - cargo build --release
      - docker/setup-buildx-action@v4
      - docker/build-push-action@v7 (cache-from/to: type=gha)

  # merge-manifest: （测试阶段已注释，正式启用时取消注释）
  #   合并两个架构镜像为多架构 manifest list
```

## 测试状态

- [x] 代码安全验证（cfg 扫描、build.rs 审查）
- [x] 原生 ARM runner 工作流搭建
- [x] 编译位置优化（runner 编译 + Docker 打包分离）
- [x] Cargo 缓存（Swatinem/rust-cache@v2）
- [x] BuildKit gha 缓存
- [ ] 构建速度对比（amd64 vs arm64 原生 runner）
- [ ] merge-manifest 启用（待构建速度测试通过后取消注释）
- [ ] 移除临时 push 触发，改回纯 `workflow_dispatch`
- [ ] 合并到上游 `main` 分支

## 相关链接

- Issue: [#1207](https://github.com/GyulyVGC/sniffnet/issues/1207)
- PR: [#1208](https://github.com/GyulyVGC/sniffnet/pull/1208)
- Branch: `feat/docker-arm64-support`
