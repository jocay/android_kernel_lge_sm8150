# LG G8（alphaplus）内核编译总结

日期：2026-10-01
对应系统：`lineage-23.2-20260807-UNOFFICIAL-alphaplus`（内核 `4.14.357-openela-perf+`，补丁级别 2026-08）

在这版 LineageOS 的内核源码上编出了可开机的内核，集成了 KernelSU-Next 和 Droidspaces 容器支持，并把手机配置成常开的服务器 / 旁路由。只替换 boot 分区里的内核，ramdisk（同时也是 recovery）、dtb、dtbo 和 vendor 分区保持官方原样。

---

## 一、结果

| 刷机包（`out/` 下，未入库） | 内容 | 真机状态 |
|---|---|---|
| `G8-alphaplus-stock.zip` | 官方配置原样重编 | 已验证：正常开机 |
| `G8-alphaplus-ksu-next.zip` | + KernelSU-Next | 已验证：正常开机，SELinux Enforcing，`su` 得到 `u:r:ksu:s0`，管理器被识别 |
| `G8-alphaplus-ksu-droidspaces.zip` | + Droidspaces（含 `USER_NS`） | 已验证：`droidspaces check` 全部通过，容器可启动 |
| `G8-alphaplus-ksu-droidspaces-server.zip` | + BBR / fq_codel | 已验证：BBR 与 fq_codel 生效，配合服务器模块开机正常 |
| `G8-alphaplus-official-kernel.zip` | 官方 0807 内核原件，同样的打包方式，回滚用 | 已验证：可刷入并开机 |

五个包的内核版本串都是 `4.14.357-openela-perf+`，与官方一致。

SHA-256：
```
235886600f211502bc51bf39b9920455488f915cef681ce1d3984614107143e7  G8-alphaplus-stock.zip
bc5fe5a0b95de33179bfad31e55e7bdcaa06aa17ac66b2e873c09fac6eebed8a  G8-alphaplus-ksu-next.zip
7afcc5cade2bd4005e582263b517cb3a24b07ab5d2a297456f08c3983153edb9  G8-alphaplus-ksu-droidspaces.zip
31f80884c906672bf7f4710cb7c2d895e2213d709fce20fe8a28271af84cbd33  G8-alphaplus-ksu-droidspaces-server.zip
14b209b720c3cd5a0aef28be60c22b58cb43f576e081734945b47765a329b6b8  boot.img（官方 0807，取自 OTA 包）
```
回滚包每次构建都会重新打包，内容不变但哈希会变，所以不列。

---

## 二、这台机器和小米 11（venus）的差异

| 项目 | 小米 11 | G8 |
|---|---|---|
| 刷机方式 | fastboot 刷 `boot.img` | 没有 fastboot，只能在 Lineage Recovery 里 `adb sideload` AnyKernel3 包 |
| 刷坏的后果 | 重刷即可 | recovery 和系统共用 boot 里的内核，内核起不来时 recovery 也进不去，只能 9008 |
| boot 头部 | v3 | v2：内核 gzip 压缩，带独立 dtb，cmdline 在头部 |
| 预编译模块的约束 | vermagic + 符号 CRC | 模块签名（见第八节），ABI 检查只用来验证构建是否忠实 |
| 版本串 | 固定 `-g<hash>` 后缀 | 只需保证结尾的 `+` |
| 配置 | ThinLTO + CFI | 无 LTO、无 CFI |
| 链接器参数 | — | 必须显式传 `LD=ld.lld`，否则这棵树检测不到 lld，丢掉官方用的 `-O2` |
| 设备树 | — | 不重编：树内 dtc 解析不了这些 overlay，dtb / dtbo 沿用官方 |
| KernelSU 挂钩 | 手动挂钩 | 手动挂钩（唯一可用的模式：kprobes 未开，改系统调用表要 4.17+） |
| Droidspaces | GKI 方案，字段放进 KABI 预留槽位 | non-GKI 方案，选项更全，带 cgroup 补丁；内核 ABI 随之改变 |
| 厂商温控 | `mi_thermald` | `vendor.thermal-engine` 的外壳温度规则 |

另外两点：
- 仓库 HEAD 比手机上的 0807 内核多一个提交（9 月 6 日的亮度修复，删了一行）。回退它之后编出的内核，15 万个符号的顺序与官方一致，全部代码段符号地址相同，差异只在两个编译时生成的内嵌数据块（内核配置、内核头文件包）。交付的包按 HEAD 编。
- 手机上实际安装的是 OTA 包里的 0807 boot；另有一个单独流传的 0805 `boot.img` 与它不同，不能当基准。

---

## 三、编译环境

| 项目 | 值 |
|---|---|
| 主机 | WSL2 Ubuntu，24 线程 / 15 GB 内存 |
| 编译器 | AOSP `clang-r563880c`（Clang 21.0.0，build 14054515），与官方内核 banner 相同 |
| 构建选项 | `LLVM=1 LLVM_IAS=1 LD=ld.lld` |
| 内核配置 | 官方内核内嵌配置（`CONFIG_IKCONFIG`）+ 配置片段；原样 `olddefconfig` 后与官方 0 项差异 |
| 打包工具 | AOSP `android-16.0.0_r4` 的 `mkbootimg`、`avbtool`；AnyKernel3 模板取自一个在本机上验证可刷的包 |
| 其他工具 | `payload-dumper-go` 2.1.0（解 OTA），`vmlinux-to-elf`（比对符号表，仅验证用） |
| 工具目录 | `~/android/tools`（`toolchains/`、`boot/`、`ota/`、`anykernel/`、`analysis/`、`ksu/`、`droidspaces/`、`downloads/`） |

一次完整编译约 1–2 分钟。

---

## 四、分支与提交

| 分支 | 用途 |
|---|---|
| `lineage-23.2` | 官方源码 + 构建脚本，编出来是无 root 的原版内核 |
| `lineage-23.2-ksu` | 在上面基础上加 KernelSU-Next、Droidspaces、服务器化 |

`lineage-23.2-ksu` 上的提交，自下而上：
```
build_boot.sh: build script for LG G8 (alphaplus)            （也在 lineage-23.2 上）
alphaplus: integrate KernelSU-Next (legacy, manual hooks)
netprio_cgroup: use the css ID instead of the cgroup ID
alphaplus: enable Droidspaces container support
alphaplus: default to BBR and fq_codel
alphaplus: add the server tuning KernelSU module
docs: add build summary
```

---

## 五、做了哪些改动

### 1. 构建脚本 `build_boot.sh`
- 从 OTA 包里解出官方 `boot.img`、`dtbo.img`、`vbmeta.img` 和 vendor 里的 14 个模块；boot 头部的全部字段、AVB 属性都从官方镜像实时读取。
- 用 `.scmversion` 固定版本串结尾的 `+`，编译后核对版本串，不一致就中止。
- 核对官方 vendor 模块依赖的符号 CRC（默认只警告，`STRICT_ABI=1` 时报错）。
- 产物：AnyKernel3 刷机包（带机型检查，非 alphaplus 拒刷）、官方内核回滚包、完整的 `boot.img`（备 9008 用）。

### 2. KernelSU-Next
- 以 submodule 引入，固定在 legacy 分支提交 `cd739c78`，内核报告版本 33304，用户态接口版本 4，对应管理器 v3.4.0。
- 手动挂钩点在 `fs/exec.c`、`fs/open.c`、`fs/stat.c`、`fs/read_write.c`、`kernel/reboot.c`、`drivers/input/input.c`。
- `fs/namespace.c` 补了 `path_umount()`。
- `include/linux/seccomp.h` 里加了一段注释，用来阻止 KernelSU 的 Kbuild 在编译时往 `struct seccomp` 插字段。它其余的编译期 `sed`，要么已手工打进源码，要么在这棵树上不会触发（树里已有 `selinux_inode()` / `selinux_cred()`）。

### 3. Droidspaces
- 配置片段 `droidspaces.config`，只列官方配置缺的：`SYSVIPC`、`POSIX_MQUEUE`、`PID_NS`、`IPC_NS`、`CGROUP_DEVICE`、`CGROUP_PIDS`、`CGROUP_NET_PRIO`、`DEVTMPFS`、`NF_TABLES`、`USER_NS`，以及 NAT / UFW / Fail2ban 用的 netfilter 选项；`BRIDGE_NETFILTER` 由模块改为内置。
- cgroup 补丁手工打入 `kernel/cgroup/cgroup.c`：Android 用 `noprefix` 挂载 cpuset，容器要找的是 `cpuset.cpus` 这类带前缀的名字，补丁为它们建链接。上游另一个 xt_qtaguid 补丁不适用，这棵树没有该文件。
- `CGROUP_NET_PRIO` 原本编不过，按上游做法把 netprio 改为使用 `css->id`。
- `NF_TABLES` 只开了文档要求的核心，没开各协议族子选项；容器里请用 `iptables-legacy`。

### 4. 服务器化（内核部分）
配置片段 `server_net.config`：默认拥塞控制由官方的 BIC 改为 BBR（bic、cubic 仍可切换），默认队列算法由 `pfifo_fast` 改为 fq_codel，同时内置 fq。

三个片段合计使配置相对官方多出或改变 108 行。被改动的官方选项只有两处：默认拥塞控制的选择（`DEFAULT_BIC` 换成 `DEFAULT_BBR`）和 `BRIDGE_NETFILTER`（m → y）；其余都是新增。

---

## 六、校验

每个刷机包出包前都做了这些静态检查：

| 检查 | 结果 |
|---|---|
| 内核版本串 | 与官方相同 |
| 配置片段 | 每一项都在最终配置里生效 |
| 刷机包内容 | 与参考包相比只有 `Image` 和 `anykernel.sh` 不同 |
| 完整 `boot.img` | 头部除内核大小外与官方一致，ramdisk、dtb 逐字节相同，`avbtool verify_image` 通过 |
| KernelSU 挂钩点、cgroup 补丁 | 反汇编确认都编进了内核 |
| 原版与 KSU 构建的符号 CRC | 官方模块依赖的 906 个全部匹配 |

原版构建另外确认了：重编出的 14 个模块，代码段和数据段与官方逐字节相同。

静态检查只能说明镜像格式正确、构建忠实；功能以第一节的真机结果为准。

---

## 七、服务器化（运行时部分）：`android/alphaplus_server/`

一个 KernelSU 模块，开机自动应用。可调项在 `config.sh`，开机日志在手机的 `/data/adb/modules/alphaplus_server/boot.log`。

真机查到的温控情况：降频来自 `vendor.thermal-engine` 按外壳温度（`vts`）执行的规则，36°C 起超大核失去最高频率，44°C 时四个大核被压到 0.83 GHz、小核 1.17 GHz，42°C 起限 GPU。内核自己的温区只在 85°C（板级）和 110°C（结温）才动作。

| 项目 | 做法 | 真机结果 |
|---|---|---|
| 温控降频 | 开机早期从原厂配置里去掉外壳温度规则，绑定挂载覆盖原文件；每次开机从原厂文件重新生成，vendor 分区不改 | thermal-engine 启动即加载新配置，外壳规则 0 条，其余规则保留 |
| CPU | 三个簇 performance 调频，大核和超大核保持在线，关闭深度空闲状态 | 三簇都在最高频，8 核在线 |
| 防休眠 | 关闭 Doze，持有唤醒锁 | 生效 |
| 充电上限 | LineageOS 充电控制，80% | 生效，高于 80% 时停止充电 |
| TCP | BBR、fq_codel、加大缓冲、关闭空闲后慢启动、TFO | BBR 生效，`eth0` 上是 fq_codel |
| 路由转发 | IPv4 / IPv6 转发，关闭反向路径过滤，在 `oem_fwd` 链放行转发 | 设置已生效；实际旁路由流量未测 |
| 联网检测与 NTP | 检测地址换成国内可达的，NTP 换成 `ntp.aliyun.com` | 以太网显示为已验证 |
| WiFi | 关闭省电、强制高性能和低延迟模式，每 30 秒检查 | 未测（手机用有线，WiFi 关闭） |
| adb | 开机监听 TCP 5555，关闭授权 | 用密钥未授权过的 adb 客户端可直接连接 |

几点说明：
- **保留的保护**：thermal-engine 里按温度限制充电电流的规则、它的结温规则，以及内核温区，都没有动（`DISABLE_KERNEL_PASSIVE_TRIPS=0`）。
- **adb 免认证的代价**：能访问 5555 端口的人都能拿到 shell；Shell 在 KernelSU 里被授予 root 时，等同于拿到 root。只适合可信的局域网。
- **转发放行是不分接口的**：任何接口之间的转发都被接受。只跑本机服务时把 `ROUTER_FORWARDING` 设为 0。

打包与安装：
```bash
android/alphaplus_server/pack.sh /tmp
adb push /tmp/alphaplus_server-v1.0.zip /data/local/tmp/
adb shell su -c "ksud module install /data/local/tmp/alphaplus_server-v1.0.zip"   # 重启后生效
```

---

## 八、如何复现

```bash
git clone -b lineage-23.2-ksu --recurse-submodules https://github.com/jocay/android_kernel_lge_sm8150.git
# 把手机上那版系统的 OTA 包（lineage-*-alphaplus.zip）放到 ../images/
# 以及一个能在本机刷入的 AnyKernel3 包作为打包模板（见脚本里的 AK3_REF_ZIP）
./build_boot.sh                                              # 全部功能
EXTRA_CONFIGS="kernelsu_next.config" ./build_boot.sh         # 只要 KernelSU-Next
EXTRA_CONFIGS= ./build_boot.sh                               # 原版内核
```
KernelSU-Next 的 submodule 不能浅克隆，它的版本号按提交数计算。

刷入：进 Lineage Recovery → Apply update → Apply from ADB，然后
```
adb sideload out/G8-alphaplus-custom.zip
```
WSL2 里看不到 USB 设备，需要用 Windows 侧的 `adb.exe`。回滚用同目录的 `G8-alphaplus-official-kernel.zip`，前提是 recovery 还进得去；否则用 9008 写入官方 `boot.img`。

配套应用：KernelSU-Next 管理器 v3.4.0、Droidspaces v6.6.0。

---

## 九、注意事项

- **官方 vendor 模块不再加载**：内核强制模块签名，密钥是每次构建临时生成的，重编的内核不认官方模块。官方内核下实际加载的是 `rmnet_perf` 和 `wmc_drv`（蜂窝数据相关），这台机器不需要。加入 Droidspaces 之后内核 ABI 也变了（官方模块依赖的 906 个符号里 463 个 CRC 不同），要用这些模块只能随内核重编。
- **`CONFIG_USER_NS` 的代价**：所有普通应用也能创建用户命名空间，Android 内核通常关闭它。它只为容器内运行 Docker 而开；不需要时删掉 `droidspaces.config` 最后一行重新编译。
- **管理器版本要匹配**：内核的用户态接口版本是 4。用旧的 v3.3.0 管理器时，root 可用但 ksud 会跳过所有开机阶段，模块不运行。
- **官方系统升级后**：换上新 OTA 包重新运行脚本即可，它会重新读取配置和版本串。源码需要与新内核对应；可用 `EXTRA_CONFIGS= STRICT_ABI=1 ./build_boot.sh` 检查原版构建的 CRC 是否仍然全部匹配。温控配置文件如果改了名字或结构，模块会在日志里报告并保持原厂配置不动。
- **升级 KernelSU-Next 时**：重新检查它的 `kernel/Kbuild` 是否新增了编译期修改内核源码的 `sed`，并核对各挂钩函数的签名。
- **安全模式**：开机时连按三次音量下键可禁用所有 KernelSU 模块。
