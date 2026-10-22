# 方案一：Opus 5.5 主控，Antigravity CLI（agy）做子代理

和 `主控公共规则.md` 一起使用。agy 不在 OpenCode 里跑，所以本方案要建沙盒、拷回，并给用户监控命令。

## 一、模型和档位

| 模型 ID | 档位 | 用途 |
|---|---|---|
| `gemini-3.8-flash-low` / `-medium` / `-high` | 档位写在模型名里 | 主力，绝大多数任务 |
| `claude-opus-4-6-thinking` | 可加 `--effort low/medium/high/xhigh/max`（对这个模型是否生效待验证） | 少数关键的预调研或高风险任务，一次最多一两个，不并发 |
| `claude-sonnet-4-6` | 同上 | Opus 4.6 额度用完时的备用。第一次用前先发一个小请求，确认它和 Opus 是否共用额度；共用就在这里注明，不再当备用 |
| `gpt-oss-120b-medium` | 只有 medium | 可用但不启用 |

先用 `agy models` 确认这些 ID 仍然可用。

### 类型到起步档位

| 类型 | 起步 |
|---|---|
| A 纯机械 | flash-low |
| B 固定写代码 | flash-low |
| C 常规实现 | flash-medium |
| D 较难 | flash-high |
| E 高风险 | flash-high，主控细审；必要时 Opus 4.6（不并发） |
| F 预调研和规划 | Opus 4.6 或 Sonnet 4.6（一两个）；额度不够时用 flash-high |

升档顺序：flash-low → flash-medium → flash-high → Opus 4.6（需用户同意用 xhigh 以上的 `--effort`）。

### 额度

- Claude 模型的个人额度很小：实测并发 8 个长任务几十秒内就触发 429「Individual quota reached」，约 5 小时后重置。
- 结果里 `status` 为 ERROR 或日志出现 `RESOURCE_EXHAUSTED`：Claude 模型换回 Flash 重派；Flash 也用完时停下来告诉用户。
- 并发：Flash 实测 8 个可以；Claude 模型一次最多一两个。换了环境或第一次使用时，先用简单任务实测并发（例如让多个实例各画一张「鹈鹕骑自行车」SVG），看耗时、退出码和有没有限流，再定上限。

## 二、环境确认（每次会话开始做一次）

- 程序路径：`$env:LOCALAPPDATA\agy\bin\agy.exe`。安装后已启动的终端 PATH 不会刷新，一律用完整路径。
- `agy models` 能列出模型说明已登录。没登录时停下来请用户在浏览器里登录，不要尝试绕过。
- 权限配置实际从哪个文件读取，以启动日志为准：`~/.gemini/antigravity-cli/log/cli-*.log` 里搜 `stored shared config permissions`。文档写的是 `~/.gemini/antigravity-cli/settings.json`，实测有版本读 `~/.gemini/config/config.json` 的 `userSettings.globalPermissionGrants`。
- 看一下 `config.json` 里的 `nonWorkspaceFileAccessPolicy`。如果是 ALLOW，agy 能读工作区以外的文件，隔离只能靠「敏感文件不在它够得着的地方」或显式的 `read_file` deny 规则。

## 三、沙盒和临时文件（放 G 盘）

- 沙盒、临时目录、派单、日志都不放系统盘（C 盘），放 `G:\agy-work\`：`sandboxes\`、`tmp\`、`dispatch\`。
- 复制沙盒：把源码、测试、脚本等目录复制进去，不复制 `.env`、密钥文件、真实数据目录。另存一份 `<沙盒>.orig` 作为改动前的快照。工作区干净时也可以用 git worktree。
- agy 只在沙盒里读写。主控在沙盒里核对、复跑测试，通过后按本批允许修改的文件清单拷回项目。拷回时校验项目里的文件仍和快照一致，防止覆盖别人的改动。拷回后在项目里再跑一次检查。
- 启动 agy 前把当前进程的 `TEMP`、`TMP` 指到 `G:\agy-work\tmp\<任务>`。agy 跑的测试会继承这个设置。
- PowerShell 脚本里有中文时，存成带 BOM 的 UTF-8，否则 Windows PowerShell 5.1 解析会出错。

## 四、沙盒规则文件

- 在沙盒根目录放一份 `AGENTS.md`，agy 每轮自动读入。不要往真实项目里加这个文件，除非用户同意。
- 内容控制在一到两屏，只写稳定规则：禁止事项、编码约定、项目约定（安全写法、lint 为 0、测试隔离到临时目录）、允许运行的检查命令（原样写出完整命令行，带超时）、报告格式和完成短语、不提前结束。
- 写明「查找和阅读代码只用文件工具，不用终端命令」。
- 每批特有的要求写在派单里，不写进规则文件。

## 五、派单命令

- 派单内容写进文件，复制到沙盒根目录的 `TASK.md`，`-p` 只传一句短英文。不要把派单原文传给 `-p`：PowerShell 5.1 会把参数里的双引号拆错，中文长文本也容易乱码。
- 用 shell 工具的 workdir 指定沙盒为工作目录。
- `--print-timeout` 必须设，shell 工具的超时也要设。较长任务放后台运行，等完成通知，不轮询。
- 启动 agy 的 PowerShell 进程先设 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`，否则日志里的中文会乱码。

首轮：
```powershell
Copy-Item '<派单文件>' '<沙盒>\TASK.md' -Force
$env:TEMP = 'G:\agy-work\tmp\<任务>'; $env:TMP = $env:TEMP
[Console]::OutputEncoding = [Text.Encoding]::UTF8
& "$env:LOCALAPPDATA\agy\bin\agy.exe" -p 'Read AGENTS.md and TASK.md in the current directory, then carry out TASK.md exactly.' --model <模型ID> --mode accept-edits --output-format stream-json --print-timeout 2400s 2>&1 | ForEach-Object { Add-Content '<日志目录>\<任务>.log' ([string]$_) -Encoding utf8 }
```
续派（同一会话，保留上下文）：加 `--conversation <conversation_id>`。

- 需要改文件时加 `--mode accept-edits`。只读任务也要写报告文件时，同样加上，并在派单里写明只许写报告。
- 结果 JSON 的字段：`conversation_id`、`status`、`response`、`denied_actions`、`usage`、`num_turns`、`duration_seconds`。
- `status` 为 SUCCESS 不代表任务完成。命令被拒后 `response` 常是空的，要看 `denied_actions`；更细的过程在 `~/.gemini/antigravity-cli/brain/<conversation_id>/.system_generated/logs/transcript.jsonl`。

## 六、权限

- 禁止使用 `--dangerously-skip-permissions`。
- 无界面模式下，没放行的终端命令一律被拒，而且一被拒这一轮就结束（`status` 仍是 SUCCESS，`response` 为空）。被打断时用 `--conversation` 续派：说明哪条命令被拒、让它重读规则、从中断处继续。
- 经用户同意后，可以只放行检查类命令（测试、lint、语法检查）：
  1. 先备份权限配置文件。
  2. 往 allow 里追加，不删用户原有的条目。
  3. 写成 `command(regex:...)`，实测是整行匹配。
  4. 正则里排除串联和注入字符，例如参数部分用 `[^;&|<>`$]*`。
  5. 解释器写完整路径。
  6. 放行后做一次金丝雀测试：让 agy 依次跑一条放行的和一条没放行的命令，确认前者能跑、后者被拒。
- 放行测试命令等于允许执行测试代码，而测试代码 agy 可以改。所以测试只能在沙盒里跑，沙盒里不能有真实密钥和真实数据。

## 七、给用户的监控命令

- 派单输出用 `--output-format stream-json`，每行追加到 `<日志目录>\<任务>.log`（UTF-8）。
- 给用户一个监控脚本和一行启动命令，让用户在自己的 PowerShell 里实时看，不要只给一次性打印的命令。脚本持续跟随日志目录下所有任务的日志，把每个事件翻成一行：时间、任务名、工具名（读文件、改文件、跑命令）、目标路径或命令、错误、最终结果和被拒操作；窗口标题显示正在运行的 agy 数量。
- 现成脚本：`G:\agy-work\bin\watch-agy.ps1`，启动命令：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File G:\agy-work\bin\watch-agy.ps1
```
- 每波结束把日志移进子目录（例如 `agy-logs\W1\`），监控窗口就只显示新任务。

## 八、清理

- 派单一律用 JSON 输出，记下每个 `conversation_id`。
- 结束后只删本次新增的：
  - 每个 conversation_id 对应的 `antigravity-cli/conversations/<id>.db`、`brain/<id>/`、`annotations/<id>.pbtxt`、`presence/<id>.lock`。
  - 本次任务启动时间前后几秒内新建的 `log/cli-*.log`、`crashes/crash_*.log`、`implicit/*.pb`。时间段内有用户自己的会话在跑时，按内容或进程号区分，分不清就不删并告诉用户。
  - `cache/last_conversations.json` 里本次沙盒路径对应的项（只删这些项）。
  - 沙盒和临时目录。agy 的报告先另存，日志按波次归档。
- 不动：用户自己的会话和 agy 进程、共享数据（如 `jetbox_summaries_proto.pb`）、MCP 缓存、配置文件（主控改过的权限按用户意见保留或还原）、agy 程序本身、项目里原有的改动。
- 删完按 conversation_id 搜一遍文件名，确认没有残留。文件被占用删不掉时，重试一次就停，告诉用户手动删除的命令。
