# 新建绑定

`SKILL.md`「绑定」的 info 返回 not-bound/0 时，读这一份。绑定前唯一允许的写入就是这里的步骤，而且要用户先确认。运行中只调用脚本，不打开源码，不读 docs。

1. 沿用 info 返回的 normalized、project_id、project_dir、registry_file。给用户看项目目录、项目标识、默认档案路径 `<project_dir>/project-profile.md`。问用户确认新建绑定，用默认路径还是已有档案。没有确认不写。
2. 调用 `bind.ps1 -Action check-profile -WorkDir <宿主工作目录> -ProfilePath <用户选定的绝对路径>`，ConfigRoot、SkillDir 若覆盖则和 info 一致。ok/0 保存 full_path；rejected/1 报 reason 并停止，请用户换路径。独立 `..` 段、skill 目录、登记目录、其他项目目录均不允许。这里只查位置和类型，不创建档案。
3. project_dir 已存在：调用 `lock.ps1 -Action check -LockPath <project_dir下write.lock> -Id <本次Id>`，尚无本次 Id 就先生成并保留，不能认领旧身份。held-by-self/0 才能直接继续。held-by-other/1、lock-empty/1、lock-missing/1 都先停下，说明可能上次没建完，问用户是否确属当前项目并恢复使用。即使缺锁也不能自动接管。空标记等 10 秒仅再 check 一次，不自动清理。用户确认目录归属后，仍须按 `SKILL.md`「崩溃标记」确认已有锁持有者已结束才清理，不自动删目录。目录不存在才按「没有才新建」创建，失败停下。
4. 按 `SKILL.md`「写入权」保留同一 Id，尚无本次 Id 才生成，不替换上步已保留的身份。调用 `lock.ps1 -Action acquire -LockPath <project_dir下write.lock> -Id <本次Id> -Task <任务>`。acquired/0、held-by-self/0 才继续；held-by-other/1、lock-empty/1 不写不删，回到 SKILL 的冲突门禁。空标记有界再查一次，不按年龄抢锁。
5. 先完成档案，再登记。档案不存在：按 `templates/project-profile.md` 起草，用户确认内容，hash 确认 file-missing/1 且从未读入时记 none，guard 通过才按「没有才新建」写入。档案存在：用 read-section 的 section 动作只请求「启用要点」，读取前后 hash 相同才成对保留。ok/0 检查内容；partial/1 缺该节，停下请用户补好或改用默认路径新建；file-missing/1 停下报告。不跟随正文路径。不得把正文的 status= 当顶层状态。
6. 持锁且登记目标 guard 通过后，调用 `bind.ps1 -Action write-registry -WorkDir <宿主工作目录> -ProfilePath <确认后的full_path>`，ConfigRoot、SkillDir 和前面一致。written/0 仅代表登记已写入，必须再 info 核验；exists/1 停下问用户，不覆盖，不自动拿磁盘登记替代本次选择；rejected/1 报 reason，停止并请用户换路径。脚本只建登记目录和三行登记，不替主控创建档案或确认内容。
7. 再调用 info：ok/0 才算完整绑定并按清单读启用要点；not-bound/0 停下报告刚写登记未找到，不循环新建；skill-repo/1 按 SKILL 输出警告并停止；registry-bad/1、registry-mismatch/1 停下请用户决定重建，不自动删；profile-missing/1、profile-no-section/1 停下请用户补档案或重新绑定。

上述 lock 的 hash 只接受 ok/0 或 file-missing/1。已有文件缺失则停下处理变动。guard 必填 LockPath、Id、File、ExpectHash，ExpectHash 为配对 hash 或 none；ok/0 才写，file-changed/1 保留自己的标记并按 SKILL 的冲突三选一询问，held-by-other/1、lock-empty/1、lock-missing/1 不写不删。不能把未配对的后算 hash 当旧内容的依据。

所有调用沿用 `SKILL.md`「主控脚本运行摘要」的调用形式。每动作仅接受本步骤和 SKILL 为其列出的状态。usage/2、error/3、缺首行协议、未知状态、状态与退出码不匹配都停下原样报告，不手工替代。
