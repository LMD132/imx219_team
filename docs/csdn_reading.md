# 怎么读 CSDN（我自己找资料的通道）

实测结论（2026-09-26）：

1. CSDN 文章正文可以直接抓，不需要浏览器。CSDN 把正文服务端渲染好了，
   curl 拿到的 HTML 里 div#content_views 就是全文，用 tools/csdn_read.py：

       python tools/csdn_read.py <文章URL>
       python tools/csdn_read.py <文章URL> --chars 0 --out docs/notes/名字.md

   已实测 149813034（FPGA sobel 双 FIFO 滑窗）：提到 12551 字正文，退出码 0；
   页面没有正文时退 3（登录墙 / 已删除 / 试读截断）。

   注意：本机 Python 的 urllib 直连会超时（和 api.github.com 一样），
   所以脚本内部走 C:/Windows/System32/curl.exe，不要改成 requests 或 urllib。

2. 浏览器也能用：Codex 内置浏览器可以打开 so.csdn.net 搜索页、读结果列表、
   点进文章读无障碍树。已实测能读到标题、作者、阅读量、点赞数、摘要。

3. 会员文章的限制（重要）：内置浏览器里 CSDN 是未登录状态（页面上还是"登录"按钮），
   你自己的会员登录在你自己的 Chrome 里，不共享给我。所以：

   * 公开文章：用 tools/csdn_read.py 直接读，最省事；
   * 标了 VIP 的文章：我这边只能拿到试读部分，抓不到全文。要读会员文章，
     得在内置浏览器里登录一次（你自己输账号，我不碰密码），或者你把文章复制给我。

## 已找到的相关线索（Sobel 边缘检测方向，非 VIP）

* FPGA sobel 边缘检测之双 fifo 实现滑动矩阵窗口
  https://blog.csdn.net/qq_74207145/article/details/149813034
  双 FIFO 滑窗加边界补零，和我们 median_filter_3x3_720p.v 的行缓存同构，
  还讲了 FIFO 的 normal 与 show-ahead 模式差异。
* （二）FPGA-Sobel 边缘检测
  https://blog.csdn.net/shx_1314200/article/details/162304224
  讲了 Sobel 在流水线里的位置（去噪和灰度化之后、特征提取之前）。
* FPGA 图像处理之 Sobel 边缘检测
  https://blog.csdn.net/qq_43156031/article/details/143229043
  实测描述阈值选不对显示效果就废。
* 基于 FPGA 的 Sobel 实时图像边缘检测系统
  https://blog.csdn.net/m0_48770376/article/details/147940172
  Cyclone IV 加 OV7725 加 VGA，含 3x3 滑窗缓冲与按键切模式。

标 VIP 的（bingbudingxz、zazazaz1、dengfenglai123 等）先别当资料源，抓不全。

## 2026-09-26 补充：搜索也免浏览器了，以及 VIP 的实测结果

### 搜索

so.csdn.net 是 JS 应用，但它调的 JSON 接口可以直接 curl：

    python tools/csdn_search.py "FPGA 自适应阈值 边缘检测"
    python tools/csdn_search.py "FPGA canny" --pages 2 --only-vip

每条结果带 price 和 vip_view_auth，工具据此标 VIP 或 free，并打印阅读量、
点赞、日期、摘要。实测查询 total=266、一次返回 30 条。

### VIP 全文：仍未解锁（重要）

内置浏览器当前**是登录状态**（导航里有 个人中心、我的钱包、浏览历史、消息、
已购上新，没有登录/注册按钮），但实测三篇 VIP 文章仍然只给试读：

* dengfenglai123/104888536：正文 620 字，末尾停在"图1 系统整体框图"，页面上有"阅读全文"
* accfpga/105746422：正文 517 字，同样有"阅读全文"
* bingbudingxz/123881389：正文 2359 字，同样有"阅读全文"

也就是说：**登录成功，但这个账号在浏览器里没有生效的 VIP 权限**（文章标的是"VIP免费"，
说明是会员可读）。可能的原因：会员买在另一个 CSDN 账号上、会员还没生效/是别的产品线
（导航里有"墨衍 MoGrow"），或者这些文章属于需要单独购买的付费专栏。

另外记录两条技术事实：

* Codex 内置浏览器**不支持** tab_content_export（导出整页为文件），所以正文只能靠
  无障碍树或剪贴板搬；
* 内置浏览器支持 playwright.evaluate，可以精确量正文长度、读付费墙文案、
  确认登录状态（这是上面那些数字的来源），比整棵无障碍树省很多。
