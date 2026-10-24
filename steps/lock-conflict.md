# 标记冲突和崩溃标记

lock 的 acquire、check、release、guard 返回锁冲突，或 guard 返回 file-changed 时读这一份。调用形式见 `SKILL.md`「主控脚本运行摘要」。只调用，不打开源码，不读 docs。主控始终保留并显式传同一个 Id，不用脚本生成的新 Id 认领旧锁。

## 标记已经在

held-by-other/1：不写、不删，按返回的 started、age_minutes、task、holder_id8 原样列出开始时间、经过分钟、任务和标识前八位，停下问另一边是否还在。时间无法解析就如实报告空值，不能据年龄抢锁。

lock-empty/1：可能是另一边正在建，包括空、不可读、缺 id、重复 id。告诉用户，等 10 秒后只用 `lock.ps1 -Action check -LockPath <标记> -Id <本次Id>` 再查一次。仍空才问，不循环。lock-missing/1：停下报告写入权已不存在，不自动重建；acquire 不会返回此状态。其他返回按下表处理。

模型记录例外：acquire 传 `-Retry 3 -WaitSec 10`，首次尝试后最多重试三次。耗尽后按最终锁状态询问，保留 attempts，不跳过记录。

| 动作和必填参数 | 状态/退出码及处置 |
|---|---|
| acquire：LockPath、Task，主控另传 Id | acquired/0、held-by-self/0 保存 Id 后继续；held-by-other/1、lock-empty/1 按上文处理 |
| check：LockPath、Id | held-by-self/0 只确认持锁；held-by-other/1、lock-empty/1、lock-missing/1 不写不删，按上文处理 |
| release：LockPath、Id | released/0 才算释放；其他三种锁状态同 check，不删别人标记 |
| hash：File | ok/0 保存与读入内容配对的 hash；file-missing/1 仅预期新建且从未读入时记 none，原有文件缺失停下处理变动 |
| guard：LockPath、Id、File、ExpectHash | ok/0 才写；file-changed/1 保留自己的标记并三选一询问；其他三种锁失败同 check |

所有调用的 usage/2、error/3、缺首行协议、未知状态、状态与退出码不匹配，一律停下原样报告，不手工替代。每个动作只接受该行动作的状态。Retry 为 0 到 10，WaitSec 为 0 到 60 秒，默认分别为 0、10。Id 非空且不含换行，比较区分大小写。ExpectHash 仅接受 none 或 64 位十六进制。

## 写之前核对没通过

guard 的 file-changed/1 表示仍持锁但文件变了，保留标记。held-by-other/1、lock-empty/1、lock-missing/1 表示不能确认写入权，不写、不删。hash 丢失先重做配对读取，Id 丢失就当别人的标记，不凭记忆写。不自动合并，不用后写的盖住先写的。只给这三项：

- 以磁盘上现在的为准，放弃这一次要写的。
- 停在这里，这一边不写。另一个会话这里停不掉，要用户自己去那个会话里让它停。
- 改用这一次会话的版本来写。只有用户明确选了这一项才写。标记仍是自己的，不删、不重建。重新读之前 hash，读后再 hash，两次相同才把该 hash 与内容成对保留，再 guard。前后不同就重读，guard 再变就停下问，不把后算 hash 配给旧内容。已确认从未读入的新文件才用 none。写入权不再属于自己时，先按 SKILL 的冲突和崩溃门禁处理，再 acquire 同一标记，拿不到就停下。

没有用户的选择，不默认任何一项。

标记可能是崩溃留下的，按 `SKILL.md`「写入权」的「崩溃标记」询问。只有用户确认另一边已经结束，才清理后重新 acquire，不因时间长自动清空。脚本没有抢锁动作。guard 到随后写入仍有非事务窗口。普通暂停不释放，结束前等本会话写者都返回，再 release。
