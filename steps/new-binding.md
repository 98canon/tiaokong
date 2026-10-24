# 新建绑定

`SKILL.md`「绑定」第 1 步找不到登记时，读这一份。绑定前唯一允许的写入就是这里的步骤，而且要用户先确认。

1. 按 `SKILL.md`「绑定」算出项目标识。给用户看项目目录、项目标识，以及档案的默认路径 `tiaokong-projects/<项目标识>/project-profile.md`。问用户：用默认路径，还是用已有的档案（用户给路径）。
2. 核对档案路径：含 `..` 的直接拒绝；其余先用 `[IO.Path]::GetFullPath(<路径>)` 解析成完整路径，再按目录边界判断（被判断的目录后面带分隔符再比，避免 `tiaokong-projectsx` 被当成 `tiaokong-projects` 下面），Windows 上比较时不分大小写。落在 skill 目录、`tiaokong-registry/` 下，或 `tiaokong-projects/` 下别的项目标识目录里，拒绝并停下。只做路径前缀判断，不扫描。
3. `tiaokong-projects/<项目标识>/` 已存在：里面的 `write.lock` 是本会话的随机标识，就接着往下做；否则停下，告诉用户这个目录可能是上次没建完的，用户确认是这个项目的，再按 `SKILL.md`「崩溃标记」问完接着用。不自动删目录。不存在就用「没有才新建」建出来，建失败也停下。
4. 按「拿标记的步骤」拿这个项目的 `write.lock`。
5. 档案不存在：按 `templates/project-profile.md` 起草，用户确认后写入。用户给的档案存在但没有 `## 启用要点`：停下，请用户按 `templates/project-profile.md` 补好，或改用默认路径新建。
6. 用「没有才新建」写登记文件 `tiaokong-registry/<登记名>.md`，三行：规范化后的项目目录、项目标识、项目档案路径。目标已存在就停下问，不覆盖。`tiaokong-registry/` 不存在就先用 `New-Item -ItemType Directory`（不加 `-Force`）建；已存在是正常情况。
