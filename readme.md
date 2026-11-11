# OmniCore-SDR-SDRPlusPlus 1.3.2

**本项目是从 [AlexandreRouma/SDRPlusPlus](https://github.com/AlexandreRouma/SDRPlusPlus) fork 的独立项目，已原生接入 OmniCore SDR（AD9361）。** 新增的 **OmniCore SDR** 源模块通过 [OmniCore Host](https://github.com/Liren66/OmniCore-SDR-Host)（OCH）直接驱动设备，无需 SoapySDR 或 libiio；SDR++ 原有的解调、录音、频率管理和其他设备支持全部保留。

This is an independent fork of SDR++ with a native OmniCore SDR (AD9361) source through OmniCore Host. Everything else is upstream SDR++.

- [下载 Windows / Linux / macOS / Android 1.3.2](https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus/releases/tag/v1.3.2-och0.7.2)
- [OmniCore Host 驱动库](https://github.com/Liren66/OmniCore-SDR-Host)
- [上游 SDR++ 完整说明（英文）](readme.upstream.md)

版本号与上游 SDR++ 保持一致，当前为 **1.3.2**。发行标签另标内置 OCH 版本，本次为 `v1.3.2-och0.7.2`。

> **固件要求**：内置 OmniCore Host **0.7.2**，适配固件 [v2026.11.08](https://github.com/Liren66/OmniCore-SDR-Firmware/releases/tag/v2026.11.08)（以及 v2026.11.07 起的成帧 USB 传输固件）。v2026.11.07 之前的旧固件需要先升级，旧版程序（内置 OCH 0.5.0）则无法打开新固件。板子运行 [OmniCore SDR Linux](https://github.com/Liren66/OmniCore-SDR-Linux) 1.3.x 时固件已包含在镜像中。

| 发布包 | 平台 | 说明 |
| --- | --- | --- |
| `OmniCore-SDR-SDRPlusPlus-1.3.2-windows-x64-setup.exe` | Windows 10/11 x64 | 安装版，可同时安装 USB 驱动，含 OmniCore Host 0.7.2 |
| `OmniCore-SDR-SDRPlusPlus-1.3.2-windows-x64.zip` | Windows 10/11 x64 | 免安装版，解压即用 |
| `OmniCore-SDR-SDRPlusPlus-1.3.2-ubuntu-noble-amd64.deb` | Ubuntu 24.04 x86-64 | 含 `libomnicore` 与 udev 规则 |
| `OmniCore-SDR-SDRPlusPlus-1.3.2-macos-arm64.dmg` | macOS 15+，Apple Silicon | 将 SDR++.app 拖到 Applications，内含 OmniCore Host |
| `OmniCore-SDR-SDRPlusPlus-1.3.2-android-arm64-v8a.apk` | Android 9+ ARM64，需 USB Host/OTG | USB 直连，无需 root |

## OmniCore SDR 源

在左侧 **Source** 下拉框中选择 **OmniCore SDR**（新配置默认选中），点击顶部 ▶ 开始接收。

| 设置 | 说明 |
| --- | --- |
| 设备 | 按序列号列出已连接的 OmniCore SDR；**Refresh** 重新扫描 |
| 采样率 | 2.5 – 61.44 MSPS（包括 30.72 / 61.44）。停止时修改 |
| Input | RX1 / RX2。停止时修改 |
| Bandwidth | AD9361 模拟滤波器 0.2 – 56 MHz；Auto = 采样率的 95 % |
| Gain Mode | Manual / Fast Attack / Slow Attack / Hybrid（AD9361 自带 AGC） |
| Gain | 手动增益 0 – 73 dB（1.3 GHz 以上上限 71 dB，4 GHz 以上 62 dB） |
| DC / IQ Correction | AD9361 的 RX 直流与正交跟踪，默认开启 |
| Show RSSI | 接收时每 0.5 s 读取 AD9361 RSSI（相对 dB，不是校准功率） |

频率范围 70 MHz – 6 GHz。接收时可直接调频、改增益、增益模式和带宽（OCH 0.4.7 起调频和改增益不会中断数据流）。面板下方显示 USB 速度、主机/设备溢出计数；USB 2.0 下超过约 14 MSPS 会提示丢样。

SDR++ 只做接收，本分支不提供 TX。发射端在每次配置时均设为最大衰减。

## Windows 使用

**安装版**：运行 `…-windows-x64-setup.exe`（需管理员权限），默认安装到 `C:\Program Files\OmniCore-SDR-SDRPlusPlus`。保留 “Install/check the libusbK driver” 选项时，安装程序会用 OmniCore Host 的驱动助手为 OmniCore SDR（VID 1A86 / PID 5537）安装 libusbK 驱动，不改动其他 USB 设备。安装时未连接设备也可以完成安装，之后连接设备并在开始菜单运行 “Install OmniCore SDR driver”。安装版的设置保存在 `%APPDATA%\OmniCore-SDR-SDRPlusPlus`，卸载时保留设置和驱动。

**免安装版**：解压 ZIP，运行 `sdrpp.exe`，设置保存在程序目录。驱动需另行安装：使用安装版的驱动选项，或 [OmniCore Host](https://github.com/Liren66/OmniCore-SDR-Host) 的 `och-driver install`。已经能用 `och find` 找到设备的电脑无需重复安装。

两种版本都包含 `omnicore.dll`、`libusbK.dll` 和全部运行库。同一时刻只能有一个程序打开设备；使用前请关闭 `och`、OnAir 等其他占用设备的程序。

Windows 版用 MSYS2 UCRT64 (GCC) 编译。包内带 RTL-SDR、HackRF 及网络类源（rtl_tcp、SpyServer、SDR++ Server 等）；Airspy、PlutoSDR、SoapySDR 等需要额外驱动库的模块未打包。

## Linux 使用（Ubuntu 24.04）

```bash
sudo apt install ./OmniCore-SDR-SDRPlusPlus-1.3.2-ubuntu-noble-amd64.deb
```

软件包名为 `omnicore-sdr-sdrplusplus`，与上游 `sdrpp` 互斥（会替换它）。安装 `/usr/lib/libomnicore.so.1` 和 udev 规则 `60-omnicore.rules`，并自动重载规则；桌面登录用户可直接访问设备，SSH 用户需加入 `plugdev` 组。插拔一次设备后，从应用菜单或终端运行 `sdrpp`。

已有的 SDR++ 配置（`~/.config/sdrpp`）会自动补上 OmniCore SDR 源。

## Android 使用

1. 安装 APK（包名 `io.github.liren66.omnicore.sdrpp`，可与上游 SDR++ 共存）。
2. 用 OTG 线连接 OmniCore SDR。系统询问时选择用 **OmniCore SDR++** 打开，并允许 USB 访问。应用运行时插入设备也会弹出授权。
3. 在 Source 中选择 OmniCore SDR 并开始接收。建议从 4 MSPS 开始；持续吞吐取决于手机 USB 接口和供电，需要时使用带电源的 USB 集线器。

Android 版包含 OmniCore SDR 源和网络类源（rtl_tcp、SpyServer、SDR++ Server、RFspace、Hermes），不含其他 USB 设备模块。OmniCore Host 在构建时打补丁，以接收 Android 授予的 USB 文件描述符，补丁见 `source_modules/omnicore_source/android/`。

## 从源码构建

OmniCore Host 以 git 子模块形式引入（`source_modules/omnicore_source/omnicore-host`，固定在 0.7.2），编译时一起构建：

```bash
git clone --recursive https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus.git
```

### Windows（MSYS2 UCRT64）

```bash
pacman -S mingw-w64-ucrt-x86_64-{gcc,cmake,ninja,pkgconf,fftw,glfw,volk,zstd,rtaudio,libusb,rtl-sdr,hackrf,codec2,ntldd} zip
cmake -S . -B build/win -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DOPT_BUILD_AIRSPY_SOURCE=OFF -DOPT_BUILD_AIRSPYHF_SOURCE=OFF -DOPT_BUILD_PLUTOSDR_SOURCE=OFF \
  -DOPT_BUILD_DISCORD_PRESENCE=OFF -DOPT_BUILD_M17_DECODER=ON \
  -DOMNICORE_LIBUSBK_DLL=<libusbK-3.1.0.0 amd64 libusbK.dll>
cmake --build build/win
bash packaging/windows/package.sh build/win release
# 安装版（Inno Setup 6.2.2 与驱动助手取自已构建的 OmniCore Host 目录）
powershell -NoProfile -File packaging/windows/build_installer.ps1 -HostDir ../OmniCore-SDR-Host
```

`libusbK.dll` 来自 [libusbK V3.1.0.0](https://github.com/mcuee/libusbk/releases/tag/V3.1.0.0)，不在 git 中。必须在 UCRT64 环境（`MSYSTEM=UCRT64`）中配置，否则 pkg-config 可能混入 mingw64 的头文件。打包脚本会检查所有 DLL 导入能否解析。

### Linux（Debian / Ubuntu）

```bash
sudo apt install build-essential cmake pkg-config libfftw3-dev libglfw3-dev libvolk-dev libzstd-dev \
  librtaudio-dev libusb-1.0-0-dev libairspy-dev libairspyhf-dev libhackrf-dev librtlsdr-dev \
  libiio-dev libad9361-dev libcodec2-dev
bash packaging/linux/build_deb.sh release
```

### Android（arm64-v8a）

需要 JDK 17+、Android SDK（platform 35）、NDK 27.2.12479018、SDK CMake 3.31.5、patchelf，以及 python3-mako。

```bash
# 依赖：zstd 1.5.6、fftw 3.3.10、volk 3.1.2 发布包放入 archives/，LIBUSB_SRC 指向 libusb 1.0.27 源码
ANDROID_NDK=... CMAKE=.../cmake/3.31.5/bin/cmake LIBUSB_SRC=... android/tools/build_deps.sh archives kit
cd android && ./gradlew -PsdrKitRoot=$PWD/../kit assembleRelease
```

发布签名：`-PkeystoreProperties=/path/keystore.properties`（`storeFile`、`storePassword`、`keyAlias`、`keyPassword`）；不提供时使用仓库内的 debug 密钥。

## 本分支相对上游的改动

- `source_modules/omnicore_source`：OmniCore SDR 源模块与 OmniCore Host 子模块。
- `core`：默认加入 OmniCore SDR 源，并把它设为默认信号源；旧配置自动补上；Android 识别 VID `1a86` / PID `5537`。
- Windows：支持 MinGW / MSYS2 编译（链接 ws2_32/iphlpapi，导出 core 符号，替换已移除的 `std::wstring_convert`）；启动时切换到程序目录，程序目录不可写（安装版）时设置改存 `%APPDATA%\OmniCore-SDR-SDRPlusPlus`。
- Android：工程升级到 AGP 8.7 / NDK 27，依赖目录可配置（`SDR_KIT_ROOT`），16 KB 页对齐，USB 授权优先 OmniCore 设备。
- 打包脚本：`packaging/windows`（ZIP 与 Inno Setup 安装版）、`packaging/linux`、`android/tools`。

## 历史版本测试情况

- **Windows 11**，OmniCore SDR（固件 `SDK_CMD_1.0_20261026_VCXO`，USB 3 SuperSpeed）：FM 广播段实收，瀑布图正常；4 / 56 / 61.44 MSPS 各连续接收 20 – 30 s，主机与设备溢出均为 0；运行中调频、改增益正常；4 次启停后正常退出。安装版静默安装后从其他工作目录启动：设置写入 `%APPDATA%`，打开设备连续接收 22 s 后正常退出。
- **Ubuntu 24.04**：`.deb` 安装、依赖解析、图形界面启动及 OmniCore 模块加载正常。该机未连接设备，未做射频实测。
- **Android**：APK 已编译、签名，并检查了 16 KB 对齐与模块打包；尚未在手机上连接设备实测。

## 许可证与来源

代码按 [GPL-3.0](license) 发布，与上游 SDR++ 相同；上游作者为 Alexandre Rouma（Ryzerth）及 SDR++ 贡献者。OmniCore Host 按 GPL-3.0-or-later 发布。本项目是独立分支，不代表上游背书，源码中保留上游版权与 Git 历史。
