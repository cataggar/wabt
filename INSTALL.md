# Installing wabt

Pre-built binaries are published to [GitHub Releases](https://github.com/cataggar/wabt/releases) and [PyPI](https://pypi.org/project/wabt-bin/).

## ghr (recommended)

[ghr](https://github.com/cataggar/ghr) is an installer for GitHub releases. It downloads the right binary for your platform, places it on `PATH`, and can upgrade it later.

```sh
ghr install cataggar/wabt
```

To install a specific version:

```sh
ghr install cataggar/wabt@v3.0.0-dev.1
```

Upgrade to the latest release:

```sh
ghr upgrade wabt
```

## uv

```sh
uv tool install wabt-bin
```

## pip

```sh
python3 -m pip install wabt-bin
```

## From source

Requires [Zig](https://ziglang.org/) 0.16. No other dependencies.

```sh
git clone --recursive https://github.com/cataggar/wabt
cd wabt
zig build -Doptimize=ReleaseSafe
```

Binaries are written to `zig-out/bin/`.
