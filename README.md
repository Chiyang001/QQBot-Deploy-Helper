<p align="center"><img src=".github/readme-app.svg" width="96" height="96" alt="炽小阳 QQ 机器人部署助手 Logo"><img src=".github/readme-divider.svg" width="24" height="96" alt=""><a href="https://space.bilibili.com/404891612"><img src=".github/readme-developer.svg" width="96" height="96" alt="炽阳001 的 Bilibili 主页"></a></p>

<h1 align="center">炽小阳 QQ 机器人部署助手</h1>

<p align="center">Windows x64 · AstrBot + NapCat QQ · 中文部署向导</p>

在 Windows 上安装 AstrBot 桌面版和 NapCat QQ，自动配置 OneBot v11 反向 WebSocket。部署向导会引导你扫码登录 QQ、填写并验证模型 API，然后重启 AstrBot 加载配置。

## 主要功能

- 检查运行环境，按需安装 Visual C++ 运行库，并通过可见窗口安装 AstrBot。
- 解压 NapCat Node 完整包，优先使用端口 `6199`，遇到端口占用时自动查找可用端口。
- 支持配置 OpenAI 兼容接口或 Anthropic 接口，完成后生成 AstrBot 和 NapCat 的桌面入口。
- 提供一键卸载和单独的 OneBot 对接修复脚本。部署日志保存在本机 `logs/`。

## 快速开始

在 Windows x64 上使用 PowerShell 5.1 或更高版本。克隆仓库，或使用 GitHub 的 **Code → Download ZIP** 下载并解压源码。

```powershell
git clone https://github.com/Chiyang001/QQBot-Deploy-Helper.git
cd QQBot-Deploy-Helper
```

从官方来源下载下列文件，按表中的文件名放在 `Deploy.ps1` 同级目录。

| 文件名 | 官方下载 | 用途 |
| --- | --- | --- |
| `AstrBot_4.26.8_windows_amd64_setup.exe` | [AstrBot Desktop v4.26.8](https://github.com/AstrBotDevs/AstrBot-desktop/releases/download/v4.26.8/AstrBot_4.26.8_windows_amd64_setup.exe) | AstrBot 桌面版 |
| `NapCat.Shell.Windows.Node.zip` | [NapCatQQ v4.18.4 Node 包](https://github.com/NapNeko/NapCatQQ/releases/download/v4.18.4/NapCat.Shell.Windows.Node.zip) | NapCat QQ 完整包，含 QQNT |
| `VC_redist.x64.exe` | [Microsoft Visual C++ x64 运行库](https://aka.ms/vc14/vc_redist.x64.exe) | Visual C++ 运行库安装程序 |

1. 右键 `一键部署.bat`，选择「以管理员身份运行」。默认安装目录为 `C:\ChiXiaoYangBot`，可在向导中修改。
2. 按提示完成安装、QQ 扫码和模型 API 配置。如果检测到已有 AstrBot 数据，请按需选择保留或清理。
3. 部署完成后，可使用桌面的 AstrBot 和「启动 NapCat QQ」入口再次启动。卸载时运行 `一键卸载.bat`，按提示确认清理范围。

只有在无法取得 Node 包时才使用 [NapCat OneKey 备用包](https://github.com/NapNeko/NapCatQQ/releases/download/v4.18.4/NapCat.Shell.Windows.OneKey.zip)。该包需要联网下载 QQ。

## 构建与自检

项目由 PowerShell 和批处理脚本组成，可直接运行。准备本地部署目录时，把仓库源码和上表中的安装包放在一起即可。

准备好依赖后，可先运行自检。自检会检查模块加载、安装包结构和端口检测，无需实际安装 AstrBot 或 NapCat。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\SelfTest.ps1
```

更多操作见 [使用说明](使用说明.txt)。
