# 调控师登记

（放在 `~/.config/opencode/tiaokong-registry/<登记名>.md`。一个项目一个。不写进度，不写方案，不写别的项目。按 `steps/new-binding.md` 先确认并完成档案，再由 bind 的 write-registry 创建，不手填、不先建空文件。）

## 登记名

由 bind 的 info 按宿主工作目录计算，返回 registry_name、project_id、registry_file、project_dir。找文件不列登记目录，不手算替代。

## 正文

实际文件只有三行，没有标题、字段名或列表前缀：

```text
<规范化工作目录>
<项目标识>
<档案绝对路径>
```

使用 UTF-8 无 BOM、LF，末尾正好一个 LF。读取时每行 Trim，忽略末尾空行，不忽略中间空行。written 后须再 info 核验，不把登记写成当作完整启用成功。exists 不覆盖，停下问用户。
