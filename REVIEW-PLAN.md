# 审查整改计划（2026-11-19）

- [x] #1 fix SSH 隧道主机密钥校验，拒绝未验证的服务端
- [x] #2 fix NapCat 进程归属识别，避免误杀其他实例
- [x] #3 fix qrsync `publicPort` 与 Node 监听端口不一致
- [x] #4 fix `start_bot.bat` 对 `astrbot_watchdog.ps1` 的路径
- [x] #5 fix `validate-repo.ps1` 对失效 Python 启动器的处理
- [x] #6 fix `status.ps1` 的 OneBot 请求方法
- [x] #7 fix `incident-snapshot.ps1` 的 OneBot 请求方法
- [x] #8 fix `smoke-test.ps1` 的 OneBot 请求方法
- [x] #9 fix Web 控制台全量重启动作与 `force-relaunch.flag` 说明不一致
- [x] #10 fix `status.ps1 -Root` 下踢线统计仍使用硬编码路径
- [x] #11 fix `check-sync.ps1 -Json` 的 `prodLen` 字段
- [x] #12 fix README 与 Web 控制台实际鉴权请求头名称不一致
