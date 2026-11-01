# Spectral Audio

Spectral Audio 是一款专为游戏场景设计的实时音频增强工具，支持 Windows 11 x64。它通过 APO 接入播放设备的音频效果链，使用神经网络模型实时增强游戏音频，并支持按游戏选择模型、调节增益强度。

当前版本为 **1.0.0**，提供 **三角洲 / Delta Force** 模型。控制台支持连续增益强度、输出增益、静音、恢复原音和播放设备切换。

PUBG急需游戏音频，有意者联系

## 安装与使用

1. 解压 `SpectralAudio-win11-x64-1.0.0.zip` 到本地文件夹。
2. 双击 `Install-SpectralAudio.cmd`，接受管理员提示，选择要增强的播放设备，等待安装和验证完成。
3. 将设备格式设为 **48000 Hz、双声道**，并启用 Windows 的“音频增强／设备默认效果”。
4. 从开始菜单“Spectral Audio”、桌面快捷方式或 `Open-SpectralAudio.cmd` 打开控制台，选择 **三角洲 / Delta Force**，调整 **增益强度（0–200%）**。
5. 增益强度控制模型的频谱提升，输出增益控制整体音量；根据需要调整静音或恢复原音。控制台运行期间启用增强，关闭后恢复进入会话前的音频效果配置。


安装时会备份目标设备的效果配置；会话看守进程负责在控制台异常退出后执行恢复。切换其他音频增强软件前，请先退出当前增强会话，避免同时修改同一设备的效果链。

程序安装在 `%ProgramFiles%\SpectralAudio`，配置和备份保存在 `%ProgramData%\SpectralAudio`。卸载可使用控制台中的卸载按钮、Windows“已安装的应用”入口，或 `Uninstall-SpectralAudio.cmd`。

## 音频处理

APO 使用原生 C++ 实现的 GRU 推理，模型参数编译进 DLL。处理流程为：

```text
PCM 浮点输入 × 32768
  → Hann 窗（1024 帧）/ hop 512
  → 64 维分析滤波器组
  → 均值与标准差归一化，裁剪到 [-10, 10]
  → 单层 GRU128
  → 64 维对数增益 → 正值 × 增益强度 → exp
  → 合成滤波器组
  → IFFT / 归一化 overlap-add
  → 输出增益平滑与 [-1, 1] 限幅
```

增益强度在 0–200% 范围内连续可调，界面精度为 0.1%。对模型输出的正对数增益乘以强度，再取 exp；负对数增益保持不变。100% 与原始模型输出一致，200% 将正对数增益乘以 2，0% 取消提升但保留衰减，因此不等同于“恢复原音”。强度变化在最多约 213 ms 内平滑过渡，不重置模型历史。该调节不需要修改或重新训练模型；中间强度是当前模型上的增益整形，不保证复现独立训练的其他模型。旧设置默认使用 100% 强度。

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


