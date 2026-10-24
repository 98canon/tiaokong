# 主控脚本长期接口

本文件用于维护，长期保留，不随开发计划归档。启用时不读 docs，运行依据是 `SKILL.md` 的运行摘要、绑定与写入权，以及两个相关分步文件。主控只调用脚本，不打开源码。不改底板、模型调度或用户确认职责。

## 共同约定

五脚本为 `scripts/control/` 下的 bind.ps1、lock.ps1、read-section.ps1、stage-commit.ps1、self-check.ps1。只支持 Windows PowerShell 5.1。调用形式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $script <参数>
```

先把实际路径放进变量，再以独立参数传递，不拼可执行字符串，不用 Invoke-Expression。PowerShell 单引号字符串内的 `'` 写成 `''`。参数只用字符串、整数。多标题或匹配词以一个字符串内的 `|` 分隔，不支持单项含 `|`。

ConfigRoot 默认用户主目录的 `.config/opencode`。SkillDir 默认脚本所在 scripts/control 的上两级。不探测别处，不联网，不读密钥，不启动服务。所有动作先在 try/catch 内校验参数再访问业务文件。缺必填值、未知动作、格式或整数范围错误为 usage。不使用进入脚本前交互验证。未声明参数或 PowerShell 启动错误可能没有协议，主控同样停下。

第一行必须是 `status=<状态>`。普通字段一行一个 `key=value`，键只用小写英文、数字、下划线，按第一个等号拆分。值的 CRLF、CR、LF 各变一个空格。read-section 的原文和 self-check 的 check 行除外。只取第一行状态，不能把原文中的 status= 当顶层状态。输出先完整缓存在内存，再统一写出，不泄漏异常前的部分成功协议。

| 退出码 | 约定 |
|---|---|
| 0 | 正常结果，包含 not-bound |
| 1 | 需规则处置的业务结果 |
| 2 | status=usage，追加 message=英文一句话 |
| 3 | status=error，追加 message=异常单行信息 |

脚本缺失、usage/2、error/3、无协议、未知状态、状态与退出码不匹配，一律停下报告，不手工替代。每个动作只接受其定义的状态。顶层 unknown 未定义；self-check 项级 unknown 是已定义结果。

## 路径、编码与写入

- WorkDir、ConfigRoot、SkillDir、ProfilePath、File、LockPath 和写入目标均为 Windows 绝对文件系统路径。只接受完整盘符路径或含非空服务器名和共享名的 UNC。拒绝盘符相对、根相对、普通相对、设备、扩展设备和备用数据流路径。两种分隔符按 Windows 规则处理，不只靠 IsPathRooted。WorkDir 必须存在且为目录。非法路径、存在但类型不符为 usage；权限和实际 I/O 异常为 error，lock 的不可读标记除外。
- 严格 UTF-8 解码，允许 UTF-8 BOM，不自动接受 UTF-16。非法 UTF-8 为 error，不写回，原字节不变。lock 已存在不可读标记仍为 lock-empty。生成的登记、标记、阶段表为 UTF-8 无 BOM、LF。输入兼容 LF、CRLF。脚本本身为 UTF-8 带 BOM、LF。
- 没有才新建：同目录以 FileMode.CreateNew、FileShare.None 排他创建 `<目标>.<8位随机十六进制>.tmp`。名称碰撞最多十次，只清理本次成功创建的文件。写完关闭句柄，同卷不覆盖改名。只有目标竞争存在才报 exists 或锁冲突，其他错误报 error。不得覆盖已有临时文件，清理失败也不能伪装成功。
- 阶段表原子替换：同样排他写临时文件，再用 Windows 原子替换，不先删除原文件。替换失败保留原文件，清理自己的临时文件。无改动的 normalize 可不写，除非需规范编码、换行。
- 隔离检查使用 GetFullPath 后不区分大小写的目录边界，不扫描目录、不解析联接。不宣称是文件系统安全沙箱或防恶意重解析点。

## bind.ps1

Action 必填。info 必填 WorkDir，可选 ConfigRoot、SkillDir。check-profile、write-registry 必填 WorkDir、ProfilePath，可选 ConfigRoot、SkillDir。

### 身份和登记

WorkDir 用原路径验证和访问，身份算法沿用字符串：去尾分隔符，反斜线换斜线，ToLowerInvariant，不用 Resolve-Path，不解析别名或联接。其 UTF-8 SHA256 为小写 64 位 registry_name。最后一段连续非 a-z0-9 换一个 `-`，去首尾 `-`，截至 24 字符后再去尾 `-`，空则 p；接 `-` 与登记名前六位为 project_id。

registry_file 为 ConfigRoot/tiaokong-registry/<registry_name>.md，project_dir 为 ConfigRoot/tiaokong-projects/<project_id>，输出完整 Windows 路径。登记三行依次为规范化工作目录、项目标识、档案绝对路径，末尾一个 LF。读时各行 Trim，忽略末尾空行，保留中间空行。不列登记目录，只检查登记的档案。

### info

依次首次命中即返回：

| status/退出码 | 条件和额外字段 | 主控处置 |
|---|---|---|
| skill-repo/1 | WorkDir 有 .tiaokong-dev，或 SKILL.md 有正好 name: tiaokong 的行 | 输出仓库警告并停止 |
| not-bound/0 | 登记不存在 | 读 new-binding，用户确认后新建 |
| registry-bad/1 | 有效行非三，追加 registry_lines | 报告，请用户决定重建，不自动删 |
| registry-mismatch/1 | 首行与规范化结果不同，追加 registry_dir | 同上 |
| registry-bad/1 | 第二行项目标识不符，reason=project-id；第三行空或非法文件路径，reason=profile-path；均 registry_lines=3 | 同上 |
| registry-bad/1 | 档案路径含独立 .. 段或命中下文禁止位置，registry_lines=3、reason=profile-location，校验前不打开档案 | 同上 |
| profile-missing/1 | 登记档案不在 | 请用户补档案或重新绑定，停止 |
| profile-no-section/1 | 档案没有正好 ## 启用要点 的行 | 同上 |
| ok/0 | 均通过 | 保存本项目路径，只按清单读启用要点 |

第一行后固定输出 normalized、registry_name、project_id、registry_file、project_dir。skill-repo 命中即返回，不打开或读取登记内容，也不输出 registry_project_id、profile_path。其余状态进入登记分支且登记存在时，再输出这两个字段，取不到为空。专用字段放最后。登记 I/O 失败为 error，不当成未绑定。

### check-profile 和 write-registry

ProfilePath 分段有独立 `..` 时 rejected/1，reason=dotdot、full_path 为空，不调用 GetFullPath。其余先验绝对路径再算 full_path。按顺序拒绝目录本身及其内部：SkillDir 为 reason=skill-dir；登记目录为 registry；项目根下但不在当前 project_dir 内为 other-project。当前 project_dir 本身为目录，不能作档案文件。

check-profile 通过返回 ok/0、full_path；拒绝返回 rejected/1、full_path、reason。只查位置和类型，不要求档案存在，不创建目录。主控通过才继续已确认步骤，拒绝则报 reason，请用户换路径并停止。

write-registry 先做相同校验，拒绝协议相同。ConfigRoot 不存在为 error/3。只在其中建登记目录，不建项目目录或档案，不验证档案内容，不替用户确认或锁门禁。written/0 或 exists/1 均追加 registry_file、project_id。exists 原字节不变，主控停问，不以磁盘登记替代本次选择。written 后必须 info 复核，不单凭写成就算启用成功。

主控仍须询问已有项目目录是否恢复，缺锁也不自动接管。先确认并完成档案，再登记。写前持锁并 guard。

## lock.ps1

Action 必填。LockPath、File 为绝对路径。标记三行为 `id=<标识>`、`started=<yyyy-MM-ddTHH:mm:sszzz>`、`task=<单行任务>`，末尾一个 LF。

Id 非空且无 CR、LF。比较区分大小写。acquire 省略 Id 会生成新 GUID，不能恢复旧身份；held-by-self 只适用于本次显式传入且匹配的 Id。主控始终生成、保留、传入同一个 Id。Task 必填，换行变空格。Retry 为 0 到 10，默认 0；WaitSec 为 0 到 60 秒，默认 10。

按三个前缀读标记。空、不可读、缺 id、空 id、重复 id 均为 lock-empty。缺 started、task 则对应字段为空。别人持有时追加 holder_id8、started、age_minutes、task；id 最多前八字符，时间距今完整整数分钟，未来可负，无法解析为空。不得按年龄抢锁。

| 动作 | 必填参数 | 状态/退出码和字段 |
|---|---|---|
| acquire | LockPath、Task；Id、Retry、WaitSec 可选 | acquired/0、id；held-by-self/0、id，不改原标记。目标已有则 lock-empty/1 或 held-by-other/1 及持有者字段。父目录不存在 usage/2、message=lock directory missing |
| check | LockPath、Id | held-by-self/0；lock-missing/1；lock-empty/1；held-by-other/1 及持有者字段 |
| release | LockPath、Id | 自己的标记删除后 released/0；其他与 check 相同且不得删除。删失败为 error/3 |
| hash | File | ok/0、hash=小写SHA256；缺文件 file-missing/1，不把目录当文件 |
| guard | LockPath、Id、File、ExpectHash | 先 check，不是自己就原样返回 check 的失败；自己的锁再按下表判断 |

acquire 失败且有余额，等待 WaitSec 再试，最多重来 Retry 次，不提前输出失败。最终失败退出 1；Retry 大于零时追加 attempts=总尝试次数，lock-empty 也如此。中途拿到或发现自己只输出成功协议。acquire 不输出 lock-missing。模型记录使用 Retry=3、WaitSec=10，耗尽后询问，不跳过记录。

内部退避测试接缝：有重试余额且 WaitSec 大于零时，统一用未限定名 `Start-Sleep -Seconds` 执行退避。临时测试包装器可拦截此调用，用有界 ready/go 事件协调释放时机。收到 go 后必须委托真实 Start-Sleep 完成原定等待，再执行真实重试。事件超时明确 FAIL，不跳过或当成功。Retry=0 或 WaitSec=0 不要求触发接缝。正式参数、输出、环境变量和等待语义均不变，不在正式脚本增加测试开关。等待仍是业务退避，不用 sleep 猜测测试同步时机。

ExpectHash 仅为不区分大小写的 none 或 64 位十六进制，否则 usage。

| 预期和现状 | guard 结果 |
|---|---|
| none 且文件不在 | ok/0 |
| none 且文件在 | file-changed/1、current_hash=实际哈希 |
| 给定 hash，文件不在 | file-changed/1、current_hash=空 |
| 给定 hash 不一致 | file-changed/1、current_hash=实际哈希 |
| hash 一致 | ok/0 |

### 主控门禁

- acquire 成功才继续并保留 Id。check 成功只确认锁，不代替 hash。release 只有 released 才算释放。
- held-by-other、lock-empty、lock-missing 都不写不删，按 lock-conflict 询问。空标记等 10 秒只再 check 一次，不无限重试。崩溃锁必须用户确认持有者已结束才清理，脚本没有抢锁动作。普通暂停不释放。
- 读待改文件之前 hash，读后再 hash，二者相同才把哈希与读入内容成对保留，不同就重读。不能把后算 hash 配给旧内容。新文件仅预期新建且确认从未读入时使用 none。原来存在后缺失则停下处理变动。身份或哈希丢失不能凭记忆写。
- 写前 guard。file-changed 保留自己的标记，问三选一：放弃本次写入并以磁盘为准；停在这里不写；用户明确选本会话版本才重新配对读取并 guard 后写。写入权不属自己时先处理锁门禁再 acquire，不自动抢锁。
- 锁与 guard 是协作门禁，不是事务。guard 到写入仍有窗口，不承诺消除全部 TOCTOU。

## read-section.ps1

所有动作必填 Action、File，只读。缺文件 file-missing/1，主控停止报告，不跳过必读文件。按逻辑行处理，末尾换行不造额外空行，真实空行保留。不跟随正文路径。

| 动作 | 参数和输出 |
|---|---|
| headings | ok/0，逐个 heading=<一基行号>:<去掉前缀的标题>，只认以 ## 加空格开头的行，不认 ### |
| section | 必填 Headings，以竖线分隔。空项、重复请求为 usage。完整标题区分大小写，不 Trim 文件标题；同名只取第一节 |
| lines | 必填 Match，以竖线分隔，空项为 usage。Ordinal 区分大小写字面匹配，不是正则。任意词命中每行只输出一次。ok/0、count=<行数>，再逐个 line=<一基行号>:<原文>；零匹配也是 ok/0 |
| stage | ok/0 后原样输出所有不以星号加空格开头的行 |

section 从正好 `## <标题>` 的行起，到下个以 `## ` 开头的行前或文件末尾；三级标题不终止。按请求顺序输出 `begin=<标题>`、原文、`end=<标题>`。全找到 ok/0；部分或全部缺失为 partial/1，最后 missing=<按请求顺序以竖线连接>。绝不输出未请求章节。主控只请求清单节，partial 必须停下报告，不能用不完整必读内容继续启用。正文 status= 不是顶层状态。

## stage-commit.ps1

所有动作必填 Action、File。缺文件 file-missing/1。找第一个以「最近提交」开头的行，不匹配 Markdown 标题前缀，找不到 no-commit-section/1。主控两者都停下报告，不擅自重建覆盖。

该行后跳过紧接的长度为零的空行，只含空格不算空行。随后连续以 `- ` 或 `* ` 开头的行构成列表，遇其他行停止，零条合法。前五条改为 `- `，后面为 `* `，仅改每行前两字符，正文不动。计数和 top 只针对此列表。列表外字符与顺序不动，仅 CRLF 规范 LF、去 BOM，保留原来是否有末尾换行。新增不吞前导空行或尾部正文，不额外增减空行。

| 动作 | 参数和状态 |
|---|---|
| add | Hash 必填，7 到 40 位小写十六进制。Text 必填非空且无 CR、LF，参数先于文件校验。列表最上加一条，格式为短横线、空格、反引号包住 Hash、空格、Text，再整理并原子替换 |
| normalize | 不加条目，按同样规则整理写回 |
| check | 只读，不规范编码也不改。只判列表前缀，符合 ok/0，否则 bad/1，均有 dash_count、star_count |

add、normalize 为 ok/0、dash_count、star_count，随后按顺序逐条 top=<完整可见行>。主控持锁且 guard 通过才写。check 的 bad 在同样门禁后 normalize 再 check，重复失败停止。脚本不验证 Git 提交，不自动提交，不更改阶段表格或阶段状态。

## self-check.ps1

仅可选 SkillDir，没有 Action。只读，不刷新 Git 索引，不改 Git 配置。SkillDir 不存在或非目录为 usage。

先收集，第一行总 status=pass 或 fail，按下表顺序输出 `check=<项>;status=<pass|fail|unknown>;detail=<英文或空>`，最后重复总状态。detail 换行变空格，分号变逗号。

| 项 | 判断 |
|---|---|
| dev-marker | .tiaokong-dev 不在 pass，在 fail、detail=development repository |
| version | VERSION 首行 Trim 后严格三段数字，等于 CHANGELOG 第一个 ## 标题的第一个三段版本号才 pass，detail 为版本。缺文件、缺版本或不等为 fail，detail 含双方值 |
| git-clean | git --no-optional-locks -C <目录> rev-parse --show-toplevel 确认规范化顶层等于 SkillDir，父仓库为 unknown。然后 status --porcelain --untracked-files=all，退出零且无输出 pass，有输出 fail、detail 为改动行数。无 git、非仓库或命令失败 unknown。Git stderr 不混 stdout，失败不吞后续检查 |
| steps | new-binding、lock-conflict、full-research、model-failure 四份 md 均为文件 pass，否则 fail，detail 逗号列缺失相对路径 |
| control-scripts | 五个控制脚本均为文件 pass，否则 fail，同样列缺失路径 |

任一 fail 则总 fail/1，主控报失败和影响，请用户决定修复，不静默修复或继续启用。只有 pass 和 unknown 则总 pass/0，逐项报告，unknown 归「无法检查」，不能称已检查通过。此脚本不替代规则冲突、模型、登录和业务环境判断。

## 维护测试入口

此节仅供维护，不是五个运行脚本的协议。正式总入口输出 validation_mode=formal-tests，保留退出码、超时、FAIL、末行汇总和实际行数自洽检查，并固定核验用例数：bind 为 54，lock 为 96，read-section 为 82，stage-commit 为 73，self-check 为 43，合计 348。少跑或多跑均失败，原因含 required case count mismatch。修改用例数量须同步维护映射并审查，不从子测试自报数生成期待值。

仅显式传入 TestRoot 且通过 TempRoot 内绝对目录及无重解析点检查后，输出 validation_mode=isolated-stubs，供主会话验证故障桩。此模式免固定数量，不免原有自洽检查，不代表正式全量。未传 TestRoot 时，即使入口是临时副本，仍核验正式数量。显式空值或非法路径不能绕过门禁。
