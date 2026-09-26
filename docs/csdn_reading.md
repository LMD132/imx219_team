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
