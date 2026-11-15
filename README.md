# Spectral Audio

Spectral Audio 是一款专为游戏场景设计的实时音频增强工具，支持 Windows 11 x64。它通过 APO 接入播放设备的音频效果链，使用神经网络模型实时增强游戏音频，并支持按游戏选择模型、调节增益强度。

当前版本为 **1.1.0**，提供 **三角洲 / Delta Force** 模型。控制台支持连续增益强度、十段均衡器、爆音抑制（DRC）、输出增益、静音、恢复原音和播放设备切换。

PUBG急需游戏音频，有意者联系

## 安装与使用

1. 解压 `SpectralAudio-win11-x64-1.1.0.zip` 到本地文件夹。
2. 双击 `Install-SpectralAudio.cmd`，接受管理员提示，选择要增强的播放设备，等待安装和验证完成。
3. 将设备格式设为 **48000 Hz、双声道**，并启用 Windows 的“音频增强／设备默认效果”。
4. 从开始菜单“Spectral Audio”、桌面快捷方式或 `Open-SpectralAudio.cmd` 打开控制台，选择 **三角洲 / Delta Force**，调整 **增益强度（0–200%）**。
5. 增益强度控制模型的频谱提升，输出增益控制整体音量；根据需要调整静音或恢复原音。控制台运行期间启用增强，关闭后恢复进入会话前的音频效果配置。
6. 在 **均衡器** 页打开 **启用 EQ**，播放中拖动滑块试听，或在下方输入框输入精确 dB 值。十段的范围均为 −6 至 +6 dB，输入精度为 0.01 dB。点击各列顶部的频率可输入 20–20000 Hz 的整数，按 Enter 或点击别处确认，右键可恢复该段的默认频率。调整自动保存，关闭 EQ 会保留各段设置，**全部归零** 只将各段增益恢复为 0 dB。提升多个频段时，可降低输出增益以减轻削波。

安装时会备份目标设备的效果配置；会话看守进程负责在控制台异常退出后执行恢复。切换其他音频增强软件前，请先退出当前增强会话，避免同时修改同一设备的效果链。

程序安装在 `%ProgramFiles%\SpectralAudio`，配置和备份保存在 `%ProgramData%\SpectralAudio`。卸载可使用控制台中的卸载按钮、Windows“已安装的应用”入口，或 `Uninstall-SpectralAudio.cmd`。

## 音频处理

APO 使用原生 C++ 实现的 GRU 推理，模型参数编译进 DLL。处理流程为：

```text
PCM 浮点输入
  → 可选 DRC（左右声道联动的峰值压缩）
  → × 32768
  → Hann 窗（1024 帧）/ hop 512
  → 64 维分析滤波器组
  → 均值与标准差归一化，裁剪到 [-10, 10]
  → 单层 GRU128
  → 64 维对数增益 → 正值 × 增益强度 → exp
  → 合成滤波器组 → 乘上 EQ 频点增益（启用时）
  → IFFT / 归一化 overlap-add
  → 输出增益平滑与 [-1, 1] 限幅
```

增益强度在 0–200% 范围内连续可调，界面精度为 0.1%。对模型输出的正对数增益乘以强度，再取 exp；负对数增益保持不变。100% 与原始模型输出一致，200% 将正对数增益乘以 2，0% 取消提升但保留衰减，因此不等同于“恢复原音”。强度变化在最多约 213 ms 内平滑过渡，不重置模型历史。该调节不需要修改或重新训练模型；中间强度是当前模型上的增益整形，不保证复现独立训练的其他模型。旧设置默认使用 100% 强度。

EQ 采用 Q 值为 0.75 的浮点峰值滤波器，计算 513 个频点的幅度响应。默认关闭。更新在 DSP 帧边界开始，经五个 hop（约 53 ms）平滑过渡，沿用既有的 FFT 和缓冲。“恢复原音”同时绕过 DRC、模型和 EQ。

爆音抑制（DRC）默认关闭。在“音频设置”页勾选 **爆音抑制**，选择默认曲线或模式 1–4，再点击 **应用设置**。它在模型前检测左右声道较大的绝对峰值，在各档软拐点范围内平滑进入压缩，左右声道乘相同增益以保持声道比例。模式 1–4 的压缩逐步增强；默认曲线对持续满幅输入约衰减 4.7 dB，模式 1–4 分别约为 6.4、8.9、11.3、13.5 dB。它会影响所有超过阈值的大音量声音，不单独识别枪声；同一时刻的较小声音也会随之降低。模型和 EQ 后的最终响度仍受它们的增益影响。

五档的阈值依次为 −14、−15、−16、−17、−18 dBFS，压缩比分别为 1.5:1、1.75:1、2.25:1、3:1、4:1。各档使用 4 dB 软拐点、0.08 ms 攻击时间常数和 60–90 ms 释放时间常数，补偿增益为 0 dB。参数按游戏录音的峰值分布与瞬态测试设置。软拐点采用公开的二次曲线，平滑作用于浮点增益衰减量。[DRC 设计论文](https://aes.org/publications/elibrary/elibrary-page/?id=16354) · [公开参数基线](https://audio.js.org/modules/dynamics-compressor/)

切换开关或曲线时经 128 个样本（约 2.67 ms）平滑过渡，正常处理时保留快速攻击，不增加缓冲延迟。关闭时保留增益衰减状态，复位时清零。开关和模式与现有参数一起保存并在 DSP hop 边界应用；旧配置保持关闭。自动验证期间临时关闭 DRC，完成后恢复设置。

也可通过运行时命令控制：

```powershell
# 开启默认曲线；模式参数为 0–4
spectral_apo_runtime.exe drc 1 0
# 关闭
spectral_apo_runtime.exe drc 0 0
```

C 接口 `spectral_stream_set_drc(stream, mode)` 使用 `0` 表示关闭，`1` 表示默认曲线，`2–5` 表示模式 1–4，调用需与处理串行。关闭后经过过渡返回精确单位增益；原音旁路保留未经 DRC 处理的延迟输入。

左右声道分别维护模型状态。APO 声明的算法延迟为 **1024 帧**，在 48 kHz 下约为 **21.33 ms**；设备端到端延迟还取决于声卡和系统音频配置。“恢复原音”在切换时平滑过渡。

## 模型与开发接口

`models/` 包含 TorchScript 模型 `predictor.ts`、归一化参数 `predictor.norm.npz`、训练检查点 `predictor.pt` 和滤波器组 `filterbanks.npz`。文件校验值见 [model-manifest.json](model-manifest.json)。检查点包含 `state_dict`、`mean`、`std` 和 `hidden`，可用于加载权重继续训练。

模型参数由 `tools/export_model.py` 导出到 `generated/model_data.cpp`。更新模型后，需重新导出并构建 DLL。

模型注册位于 [src/model_registry.cpp](src/model_registry.cpp)，按游戏和内部模型索引关联 `ModelData`；内部 `level` 用于模型兼容，不是用户增益强度。当前模型索引为 `game=2`、`level=4`；接入同架构模型时，可导出新参数并注册到相应位置。控制台通过运行时查询可用模型，也可执行以下命令查看：

```powershell
spectral_apo_runtime.exe models
```

公开 C 接口位于 [include/spectral_cpu.h](include/spectral_cpu.h)，提供模型可用性查询、音频流创建、配置、处理和复位操作。

## 构建

### Windows

安装 Visual Studio C++ Build Tools、Windows 11 SDK 和 CMake，然后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-windows.ps1
python tools/package.py --binaries build-windows/Release
```

仓库已包含导出的 C++ 模型参数，可直接用于构建。打包脚本需要 Python；重新导出模型还需安装 NumPy 和 PyTorch：

```sh
python tools/export_model.py
```

导出脚本会核对 TorchScript 与训练检查点的权重及归一化参数是否一致。

### Linux 核心构建与验证

安装 CMake 和 C++17 编译器后运行：

```sh
cmake -S . -B build-linux -DCMAKE_BUILD_TYPE=Release
cmake --build build-linux -j4
(cd build-linux && ctest --output-on-failure)
python tools/verify_model.py --library build-linux/libspectral_verify.so
```


