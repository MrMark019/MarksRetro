RETRO 单机 AI Agent 便携包 v3.6d  (XP SP3 / 32 位 Windows 专用)
================================================================

自包含文件夹:拷到任意位置都能用,不依赖大U盘其他内容。
防病毒做法:母盘留干净电脑,只拷本文件夹到一次性介质进毒区,用完即弃。

★ 唯一静态配置入口:retro.ini(记事本直接改,改完跑 agent.bat 即生效)
    upstream        服务商 HTTPS 地址(桥的转发目标,默认阿里云百炼)
    port            本机桥端口(默认 8787,一般不动)
    model           默认模型名(默认 qwen3.8-flash)
    max_tokens      单次最大输出 token(0=不限)
    context_window  上下文窗口声明(自动压缩用,128K 模型填 131072)
    key_file        密钥所在文件(默认 key.txt,第一行 sk- 开头)
    max_history     对话历史条数(内存小可调低)
    require_approval 执行命令前是否人工确认

★ 运行时改配置:不用碰 retro.ini,会话里直接敲命令(自动持久化):
    /upstream <url>  热切服务商(双写 settings.txt + upstream.txt,重启仍生效)
    /model /api /think /context /maxtok /stream 等(写 settings.txt)
     /rounds N      工具调用轮数上限(默认30,2..100;原 max_tool_rounds 文件键)
    手工重置:删 settings.txt / upstream.txt 即回到 retro.ini 默认。

文件:
  micro-agent.exe   agent 本体(fork v3:流式对话/工具展示/思考显示/上下文压缩/
                    Plan-Build 双模式/会话保存恢复/图片输入/三种API风格/GBK中文)
  micro-agent.exe.stock  官方原版备份(想换回直接改名)
  retrobridge.exe   本机 TLS 桥(HTTP转HTTPS,支持流式透传与运行时切换上游)
  ca-bundle.crt     根证书包
  models.txt        编号模型菜单(agent.bat 2 即用 2 号模型)
  key.txt           密钥唯一存放点  <-- 使用前把 sk- 密钥贴到第一行
  setup.bat         环境体检(时钟/二进制/密钥),不改任何东西
  agent.bat         日常入口:体检 -> 生成运行配置 -> 拉桥 -> 对话 -> 退出清理
  sessions\         对话自动存档目录(/save 命名,/sessions 列表恢复)
  settings.txt      运行时设置(命令自动写,可手改,删=重置)
  upstream.txt      当前服务商(切 /upstream 自动生成,优先级高于 retro.ini)

用法:
  1. key.txt 已预填本U盘绑定的密钥(换密钥才需编辑)
  2. 双击 agent.bat 开始;agent.bat 2 用菜单2号模型
  3. 会话命令速查(/help 全列表):
     /model          列服务商全部模型,编号选 /model 12
     /plan /build    只读规划模式 <-> 完整执行模式
     /img <路径>     给下一条消息附图(png/jpg/gif/webp,<=3MB);消息里直接贴图片路径也会自动识别挂载
     /compact        立刻压缩旧上下文(接近窗口上限时也会自动压)
     /sessions [n]   列出/恢复历史会话    /save <名>  /new
     /usage          上一轮 token 用量与窗口占用
     /think high     思考强度 off/low/medium/high(qwen/deepseek 新模型有效)
     /stream off     关逐字流式(极慢网络时用)
     /upstream <url> 换服务商(OpenAI 兼容端点);重启后自动重新生效,
                      启动横幅 Upstream 行显示的就是桥的真实目标
     /key <新key>    换密钥(即时生效并重写 key.txt)
     /color on|off  彩色/纯黑底白字(默认纯黑底白字,老控制台更干净)
     /thinking brief|full  思考折叠(默认brief一行摘要)/expand 展开上轮
     ESC 或 Ctrl+C 打断当前回复(不退出程序,continue 继续);空闲时连按
     两次 Ctrl+C(2.5秒内)才退出;点窗口X随时退出
     工具轮数上限 10→30,触顶会明确提示(不再无声中断)
     /api responses 或 anthropic 可切协议格式(经 /upstream 指向对应端点)
     max_tokens 超过当前端点实际上限时,自动按服务商报错钳制并重试,无需手改
     (/usage 看真实 token 用量;换端点/模型后上限各自自适应)

说明与限制:
  - Windows XP SP3+ 32位;机器自身能上网;密钥只在 key.txt,不进 config;
  - 中文输入输出已由 fork 修复(GBK<->UTF-8 自动转换,界面制表符已适配);
  - 时钟错乱(CMOS 电池)会导致 TLS 失败,启动时自动检测并尝试 NTP 同步;
  - 思考内容/流式文字需要桥在线(默认即满足);若服务商拒绝思考参数会自动降级重试;
  - 图片走 base64 随消息发送,老机器内存小注意别连发大图;历史压缩会丢弃旧图片载荷。

