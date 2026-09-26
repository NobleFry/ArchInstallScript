# 个人用的 arch linux 安装脚本和环境配置md

## 参考来源

- [arch简明指南](https://arch.icekylin.online/)
- [Shorin-ArchLinux-Guide](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/tree/main)
- [winapps-org/winapps](https://github.com/winapps-org/winapps/blob/main/docs/libvirt.md)
- [告别重启：Linux 下的 NVIDIA 显卡直通](https://blog.vconet.top/archives/nvidia-kvm-passthrough/)

在参考基础上自己加入了全盘加密与休眠，以及最基础的系统与 kde 安装。

## 目录结构

```text
MyArchGuide/
├── README.md                  # 本文件：总索引
├── docs/
│   ├── environment.md         # 系统基本配置（显卡驱动、niri/dms、zsh、paru、常用应用）
│   └── virtualization.md      # KVM 虚拟机与显卡直通
└── scripts/
    ├── README.md              # 脚本用法说明
    ├── install.sh             # 基础系统安装（UEFI + LUKS2 + Btrfs + GRUB）
    ├── post-install.sh        # 桌面环境安装（KDE Plasma + SDDM + Fcitx5）
    └── check.sh               # 休眠 / 加密启动排查
```

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [系统基本配置](docs/environment.md) | 显卡驱动、dankinstall 安装 niri 和 dms、zsh 配置、aur 助手 paru、常用应用与 xanmod 内核 |
| [虚拟机与显卡直通](docs/virtualization.md) | KVM 安装与嵌套虚拟化、Windows 11 虚拟机、VirtIO-FS 文件共享、独显直通、Looking-glass、VFIO 解绑 |
| [脚本说明](scripts/README.md) | 三个脚本的用途、运行环境与流程 |

## 安装流程

1. Arch Live ISO 中运行 [scripts/install.sh](scripts/install.sh)，装好带全盘加密与休眠的基础系统。
2. 进入系统后以 root 运行 [scripts/post-install.sh](scripts/post-install.sh)，安装 KDE Plasma 与桌面组件。
3. 按 [docs/environment.md](docs/environment.md) 配置显卡驱动、shell 与应用。
4. 需要跑 Windows 虚拟机或做独显直通，参考 [docs/virtualization.md](docs/virtualization.md)。
5. 休眠有问题时用 [scripts/check.sh](scripts/check.sh) 对照排查。

## 文档格式检查

统一用 markdownlint 校验所有 md 的格式，规则见 [.markdownlint-cli2.jsonc](.markdownlint-cli2.jsonc)（无需本地安装依赖）：

```bash
npx --yes -p markdownlint-cli2 markdownlint-cli2 "**/*.md"
```

已关闭的规则只有两条会改变正文内容的：`MD013`（中文长行不强制折行）、`MD036`（保留 `**加粗小标题**` 写法，不升级为 ATX 标题）。
