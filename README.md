# Weibo（微博只读客户端）

非官方第三方 Flutter 客户端，**访客态只读**：浏览热门/分类流、视频、热搜、搜索、用户主页与视频播放，不含发博/评论/点赞等写操作。

## 功能（v1）

- **首页**：热门 + 58 个兴趣分类（来自 `/ajax/feed/allGroups`「我的频道」「频道推荐」）的微博流，下拉刷新 + 游标分页；正文富文本高亮（话题/@/链接）、图片宫格、视频封面、转发内嵌卡、长文「全文」。
- **视频页**：推荐/短剧/电影/电视剧/综艺/游戏分类中带视频的微博大卡列表。
- **播放器**：media_kit 播放 `playback_list` 多档直链，默认 ≤720p 最高档，可切换画质；下方相关视频（`relatedVideoList`）。
- **发现**：微博热搜榜（名次/爆·热·新标/热度）+ 六大分类热词榜（band）；点击词条直达搜索。
- **搜索**：m.weibo.cn 综合搜索，一次拉取后本地分段（综合/用户/微博）。
- **详情**：完整微博 + 长文自动补全 + 评论区（**访客仅热评**，带横幅说明）+ 点赞列表 + 相关视频；转发列表访客不可见（占位说明）。
- **用户主页**：封面/头像/认证/简介/三计数 + 资料弹窗；微博、视频（含合集横列，详情页为后续版本占位）、相册三页签。
- **我的**：双栈访客身份状态（PC/m 各一对 SUB/SUBP）与手动刷新、设置、外观（沿用模板 M3 主题系统：动态取色/种子色/纯黑）、关于。

## 接口来源

全部接口来自网页端逆向整理文档（唯一依据）：

```
~/workspace/rea-probe/targets/weibo/WEIBO_API.md
```

双栈：PC `weibo.com/ajax/*` + 移动 `m.weibo.cn/api/*` 容器体系。访问前经 Sina Visitor System 换取访客 Cookie（`passport.weibo.com` / `visitor.passport.weibo.cn` 的 genvisitor → incarnate），业务请求遇 302 / `ok=-100` / 特定 403 自动重换访客重试一次。

## 访客限制（服务端硬限，非客户端缺陷）

- **评论**：只下发 1 条热评（`total_number` 照常报总数），详情页以横幅明示。
- **转发列表**：完全拦截（PC 返回「登录」提示，m 端 `ok=-100`），详情页做占位说明。
- **关注流 / 我的时间线**：PC `mymblog`、好友流 403，访客不可用——本应用不提供关注流。
- 用户时间线、全文搜索、点赞列表访客可读（走 m 栈），故主页/搜索/点赞可用。
- 图片/视频 URL 带时效签名（`Expires`/`ssig`），过期需重新拉取详情刷新。

## 登录与写操作

v1 不做。v2 计划：WebView 登录后收割登录态 SUB Cookie 复用同一数据层；SSO 账号密码直登（RSA + 可能的极验/短信）未用真实账号验证过，不在计划内。

## 构建

沿用模板 CI（`.github/workflows/release.yml`，Flutter 3.47.7）：推 `v*` 标签触发多端发布——Android APK（分架构，自签）、iOS IPA（未签名）、macOS DMG、Linux deb/rpm/AppImage/pacman、Windows zip。Android job 在 Analyze 后跑 `flutter test`。

本地：

```bash
flutter pub get
flutter analyze
flutter test
flutter run            # 或 flutter build apk / build macos 等
```

## 测试

```
test/unit/      模型解析（PC/m 双栈 fixture）、访客 JSONP 提取、计数/时间/HTML 工具
test/services/  假 Dio adapter 下的 VisitorService 流程与 WeiboService 参数拼装/访客重试
test/widgets/   StatusCard 五种形态与图片宫格布局
test/screens/   首页/详情（热评横幅）/发现/主页/我的/主壳四栏切换
test/fixtures/  自 rea-probe/targets/weibo 的 samples/raw 裁剪的真实返回
```

## 声明

本应用仅供学习交流使用，与新浪微博官方无关；数据版权归原作者及微博平台所有。
