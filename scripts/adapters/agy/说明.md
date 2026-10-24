# agy 接入通用脚本说明

agy（Antigravity CLI）通过以下方式接到通用脚本：

- 运行任务：`run-tool.ps1 -Exe "$env:LOCALAPPDATA\agy\bin\agy.exe" -ToolArgs @('-p','{PROMPT}','--model','<模型>','--mode','accept-edits','--output-format','stream-json','--print-timeout','<秒>s')`，可选 `--effort`、`--conversation`。
- 核对：先跑 `adapters\agy\check.ps1 -Id <任务>` 看 agy 结果和沙盒外访问，再跑 `check-sandbox.ps1 -Id <任务>` 看通用改动。
- 收尾：先 `adapters\agy\clean.ps1` 清 agy 会话残留，再 `clean-sandbox.ps1` 清沙盒和日志。
- 监控：`watch-runs.ps1 -Formatter <skill 目录>\scripts\adapters\agy\format.ps1 -ProcessName agy.exe`。

agy 特有的注意事项：

- 权限配置实际读 `~/.gemini/config/config.json` 的 `userSettings.globalPermissionGrants`。
- 命令授权用 `command(regex:...)`（整行匹配）。
- `nonWorkspaceFileAccessPolicy` 是 ALLOW 时，agy 能读工作区以外的文件，有风险，要加 `read_file` 的 deny 规则保护密钥文件。
- 命令被拒时这一轮会直接结束，工作做不完。
- 日志里不一定有全部会话 ID，时间窗清理可能误删用户自己同一时刻的 agy 文件，确认这段时间没有自己开 agy 才加 `-IncludeTimeWindow`。
- 参数里不要放双引号，长内容放进 TASK.md。
