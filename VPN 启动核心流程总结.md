

  步骤 1：UI层 - 用户交互的起点


   * 类: StartButton (./lib/views/dashboard/widgets/start_button.dart)
   * 角色: 用户界面，接收点击事件。
   * 流程:
       1. 用户点击屏幕上的浮动按钮。
       2. onPressed 回调触发 handleSwitchStart() 方法。
       3. handleSwitchStart 立即调用 updateController() 来播放按钮的加载动画，给用户即时视觉反馈。
       4. 同时，它调用 globalState.appController.updateStatus(bool isStart)，将“启动”这个指令派发给总控制器。

  步骤 2：应用控制层 - 业务逻辑的总指挥


   * 类: AppController (./lib/controller.dart)
   * 角色: 应用的“大脑”，负责编排业务逻辑。
   * 流程:
       1. updateStatus(bool isStart) 方法被调用，其中 isStart 参数为 true。
       2. 方法内部判断 isStart 为 true，于是调用 globalState.handleStart(UpdateTasks tasks) 方法来执行启动流程。
       3. 调用时，它传入了一个任务列表 [updateRunTime, updateTraffic] 作为 tasks 参数。这些任务将在服务启动后，由一个定时器（通过 startUpdateTasks 启动）周期性执行，用于刷新UI上的运行时间和流量信息。
       4. 在 globalState.handleStart() 方法内部，它执行了关键的调用：await service?.startVpn()，这将触发步骤3的流程。

  步骤 3：插件接口层 (Dart) - 通往原生世界的“遥控器”


   * 类: Service (./lib/plugins/service.dart)
   * 角色: Dart世界的Android原生服务“遥控器”。
   * 流程:
       1. startVpn() 方法被调用。
       2. 方法内部首先调用 clashLib.getAndroidVpnOptions()，从核心获取当前的 VPN 配置选项 (VpnOptions)。
       3. 然后，它将获取到的 options 对象进行 JSON 编码。
       4. 最后，它通过 methodChannel.invokeMethod<bool>(String method, dynamic arguments) 发起平台调用：
           *   `method` 参数为字符串 'startVpn'。
           *   `arguments` 参数为一个 Map：{'data': json.encode(options)}。
       5. 这个调用将触发步骤4的流程。

  步骤 4：原生插件的“指令接力”与服务/引擎的创建

   * 类:
       1.  ServicePlugin.kt (./android/app/src/main/kotlin/com/follow/clash/plugins/ServicePlugin.kt)
       2.  VpnPlugin.kt (./android/app/src/main/kotlin/com/follow/clash/plugins/VpnPlugin.kt)
       3.  FlClashVpnService.kt (./android/app/src/main/kotlin/com/follow/clash/services/FlClashVpnService.kt)
   * 角色:
       *   `ServicePlugin`: 指令中转站。
       *   `VpnPlugin`: 总指挥中心和服务生命周期管理者。
       *   `FlClashVpnService`: 后台服务实体和后台引擎的实际创建者。
   * 流程:
       1.  `ServicePlugin.kt` 监听到 'startVpn' 命令，并立即调用 `GlobalState.getCurrentVPNPlugin().handleStart(options)`，将指令“接力”给 `VpnPlugin`。
       2.  （流程进入 `VpnPlugin.kt`） `VpnPlugin.handleStart(options)` 方法被触发，并最终调用到 `handleStartService()`。
       3.  在 `handleStartService()` 中，通过异步绑定来创建并启动服务：
           *   a. 首次调用与服务创建: `handleStartService` 发现服务未连接，于是调用 `bindService` 并传入 `BIND_AUTO_CREATE` 标志。此操作会自动创建 `FlClashVpnService` 实例。
           *   b. 后台引擎创建: 在 `FlClashVpnService` 的 `onCreate()` 生命周期方法中，它会立即调用 `GlobalState.initServiceEngine()`，从而创建并启动后台的 Dart 引擎。
           *   c. 绑定成功回调: 系统完成服务创建和绑定后，`onServiceConnected` 方法被触发。在此方法中，`VpnPlugin` 获取到 `FlClashVpnService` 的实例，并再次调用 `handleStartService()`。
           *   d. 再次调用与核心启动: 此时 `handleStartService` 发现服务已连接，于是继续执行，调用 `flClashService.start()` 获取 `fd`，并最终调用 `Core.startTun()` 将所有参数和回调函数传递给 Go 核心。

  步骤 5：后台引擎创建层 - 建立独立的“后台世界”


   * 类: GlobalState.kt (./android/app/src/main/kotlin/com/follow/clash/GlobalState.kt)
   * 角色: 全局状态和后台引擎的创建者。
   * 流程:
       1. initServiceEngine() 方法被调用。
       2. 它会创建一个全新的、独立的 `FlutterEngine` 实例。
       3. 最关键的一步：它通过 DartExecutor.DartCallback，将这个新引擎的执行入口点指定为 `main.dart` 中的 `_service` 
          函数，而不是默认的 main。
       4. 它启动这个引擎，_service 函数开始在一个新的后台Dart Isolate 中运行。


  步骤 6：后台Dart入口 - “后台世界”的总管


   * 函数: _service() (./lib/main.dart)
   * 角色: 后台Dart环境的“main函数”和总调度，负责初始化 FFI、设置原生插件回调，并根据不同模式执行启动。
   * 流程:
       1.  `_service` 函数开始执行，并根据 `flags` 参数判断是否为“快速启动”模式 (`quickStart`)。
       2.  它创建 `ClashLibHandler` 实例（FFI桥接层）。
       3.  与原生 `VpnPlugin` 的交互与设置: 在执行主要逻辑之前，它会为 `vpn` 对象（`VpnPlugin` 的 Dart 代理）进行一系列关键的设置和监听：
           *   a. 监听停止事件: 通过 `tile.addListener` 添加监听器。当从系统磁贴（Tile）传来停止事件时，会调用 `vpn.stop()`，该调用通过 `MethodChannel` 通知 `VpnPlugin.kt` 执行停止流程。
           *   b. 设置前台通知回调: 将 `vpn.handleGetStartForegroundParams` 属性赋值为一个函数。这个函数负责在原生层需要更新通知时（由 `startForegroundJob` 触发），提供实时的流量信息，并将其编码为 JSON 字符串返回。
           *   c. 监听原生事件: 调用 `vpn.addListener(VpnListener listener)`，注册一个监听器以接收来自 `VpnPlugin.kt` 的事件，如此处的 `onDnsChanged(String dns)` 事件。
       4.  执行逻辑分支:
           *   a. 正常启动路径 (`quickStart` 为 `false`):
               *   调用 `_handleMainIpc()`，建立与前台 UI Isolate 的双向通信桥梁，进入被动监听状态，等待并处理来自前台的指令。这个过程对应了步骤7的流程。
           *   b. 快速启动路径 (`quickStart` 为 `true`):
               *   主动执行一系列初始化操作，并通过 `clashLibHandler.quickStart(...)` 直接调用 FFI 函数来快速配置 Go 核心。
               *   错误处理与停止: 检查 FFI 调用的返回值。如果返回值不为空（表示 Go 核心初始化失败），则调用 `vpn.stop()` 来确保原生服务被干净地停止，然后退出进程。
               *   启动核心: 如果 Go 核心初始化成功，则继续调用 `vpn.start(VpnOptions options)`，其中 `options` 通过 `clashLibHandler.getAndroidVpnOptions()` 获取。此调用会触发 `VpnPlugin.kt`，最终将回调函数传递给 Go 核心并启动服务。

  步骤 7：FFI桥接层 - 与Go核心的直接对话


   * 类: ClashLibHandler (./lib/clash/lib.dart)
   * 角色: 运行在后台Isolate中的、与Go核心直接对话的“FFI翻译官”。
   * 流程:
       1. 它在 _handleMainIpc 中接收来自前台UI的指令（比如“加载配置”）。
       2. 它将Dart数据“包装”成C语言兼容的类型。
       3. 它通过 clashFFI 对象，直接调用 `libclash.so` 原生库中的函数。

  步骤 8：Go核心引擎 - 最终的执行者


   * 组件: libclash.so (由 ./core/ 目录下的Go代码编译而来)
   * 角色: 真正的网络代理引擎。
   * 流程:
       1. 接收到来自 ClashLibHandler 的FFI调用。
       2. 执行真正的核心逻辑，比如启动代理、解析规则、处理网络数据包。
       3. 将执行结果返回给 ClashLibHandler，再由后者一路传递回UI界面。

附录：核心配置的来源与设置流程


文档的主体部分描述了当用户点击“启动”按钮后，App 如何获取配置并启动服务。然而，这些配置信息本身是如何被设置到 Go
核心的，则遵循另一个独立的流程。AndroidVpnOptions 等动态配置，其源头正是此流程。


1. 用户操作 (User Action)
    * 用户在 Flutter UI 的各个设置页面进行操作，例如在设置页打开 “TUN模式” 的开关、修改代理模式、编辑 DNS 或路由规则等。
    * 所有这些用户的选择和修改，都会被实时地更新并保存在由 Riverpod 管理的各种状态提供者 (Provider) 中。


2. 应用配置 (Applying Configuration)
    * 当用户完成修改并点击“保存”或“应用”（通常是右上角的勾号图标）时，会触发 AppController 中的 applyProfile() 或
      setupClashConfig() 等相关方法。


3. 收集与组装 (Collection & Assembly)
    * 在 AppController 的 _setupClashConfig() 方法中，会调用 globalState.getSetupParams()。
    * 这个 getSetupParams() 方法是一个“配置组装工”，它会从应用中所有相关的 Provider
      读取最新的用户设置（TUN、代理模式、DNS、当前配置文件等），并将这些零散的信息组装成一个结构化的、Go 核心能够理解的
      SetupParams 配置对象。


4. 通过 FFI 设置 (Setting via FFI)
    * _setupClashConfig() 方法在获取到完整的 params 对象后，会调用 clashCore.setupConfig(params)。
    * 这个调用是一个 FFI 调用，它将整个 SetupParams 对象序列化（通常是转为 JSON 字符串），然后通过 FFI 传递给
      libclash.so 原生库中的相应函数。

5. Go 核心更新状态 (Go Core State Update)
    * Go 核心引擎接收到这个完整的配置包，解析它，并用它来全面更新自己的内部运行状态。


结论:
这个“设置”流程完成后，Go核心就有了最新的、与用户UI选择完全一致的配置。因此，在主流程中（如步骤3和步骤6）调用
getAndroidVpnOptions() 时，Go核心便能根据这些最新信息，动态生成并返回正确的 AndroidVpnOptions。