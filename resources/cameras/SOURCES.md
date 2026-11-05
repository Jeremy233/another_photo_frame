# 品牌 logo 来源

这些 logo 是各公司的商标，不在本项目的 GPL 许可范围内，只用于标示拍摄器材。多数在 2026-11-04 从各品牌官网的页头（或页脚）下载；官网没有的几个来自第三方 logo 网站，见表里的说明。

每个品牌一个文件夹，文件夹名和文件名就是 `brands.json` 里的 id。文件都是处理过的版本：去掉了附带的文字（Canon 的 "Global"、Fujifilm 的 "Value from Innovation"、Ricoh 的标语、PENTAX K-3 Mark III 里的型号），并裁到 logo 自身的边缘。下载的原文件没有保留，地址见下表。

| 品牌 | 来源 |
|---|---|
| Apple | https://www.apple.com/ （导航栏内嵌 SVG） |
| Canon | https://global.canon/01cmn/img/common/logo.svg |
| DJI | https://www.dji.com/ 页脚 logo（www-cdn.djiits.com/dps/176201ad61d0753e17d860c4ca117932.svg） |
| Fujifilm | https://global.fujifilm.com/themes/custom/fujifilm_com_g2/common/img/fujifilm_corporate_logo.svg |
| Hasselblad | https://www.hasselblad.com/assets/icons/logo-white.svg |
| Kodak | 红黄版 `kodak/kodak.svg`：图形取自 https://www.kodak.com/ 页头内嵌 SVG，颜色和留白照用户提供的 Kodak.png（红 #E30613、黄 #FAB617）。单色版 `kodak/kodak-mono.svg` 是同一图形 |
| Konica Minolta | https://www.konicaminolta.us/wp-content/themes/wp-bootstrap-starter-child/assets/img/identity01g.svg |
| Linhof | https://linhof.com/wp-content/uploads/2019/01/LINHOF_logo.png （官网页头，只有 300px 的 PNG），描成矢量（红 #FF0004）。官网另有一个带王冠的盾形徽章 `Linhof_wappen1.png`，细节多、分辨率低，没用 |
| Chamonix | https://www.chamonixviewcamera.com/ 页头的 2500px PNG（`商标 (1).png`），描成矢量（深灰 #332C2B） |
| Wista | 第三方：官网 https://www.wista.co.jp/ 只有很小的 GIF，从一份 WISTA 45 产品目录封面扫描（Yahoo!拍卖的商品图）上裁出 WISTA 字样，校正 0.3° 倾斜后描成矢量。印刷扫描描出来的边缘不如官方矢量平整，以后找到更好的来源再换 |
| Plaubel | https://www.plaubel.com/Plaubel-Logo.gif （Plaubel GmbH 官网，4295px），描成矢量：黑色 PLAUBEL 字样和灰、红、灰三条斜块。`plaubel-rev.svg` 是黑字换成白字的版本。EXIF 或手填相机里含 makina 也认成 Plaubel |
| Leica | https://leica-camera.com/themes/custom/leica_redesign_theme/logo.svg |
| Mamiya | 第三方：https://seeklogo.com/vector-logo/322331/mamiya 的 600px PNG，描成矢量（红 #FC001B）。mamiya-op.co.jp 上的是 Mamiya-OP 公司的标志，没用 |
| Contax | 第三方：https://freebiesupply.com/logos/contax-logo/ 的 SVG，去掉透明底框 |
| Bronica | 第三方：https://petapixel.com/bronica-history/ 题图里的 Zenza Bronica 字标，描成矢量 |
| Minolta | 第三方：维基共享资源 https://commons.wikimedia.org/wiki/File:Minolta_Logo.svg （标注为公有领域；商标仍归原公司），裁到 logo 边缘。上方蓝色地球标志、下方 MINOLTA 字样 |
| Konica | 第三方：维基共享资源 https://commons.wikimedia.org/wiki/File:Konica_Logo.svg （标注为公有领域；商标仍归原公司），裁到 logo 边缘。左边彩虹扇形、右边 Konica 字样 |
| Nikon | https://www.nikon.com/etc.clientlibs/nikoncore/clientlibs/clientlib-site/resources/img/logo.svg 。`nikon/nikon.svg` 是从同一文件里取出的黑色 Nikon 字样，`nikon/nikon-emblem.svg` 是黄色方块标志。pngwing 上那张 Nikon 字标把棋盘格画进了图里，不是真透明，没用 |
| OM System | https://explore.omsystem.com/ 页头 logo.svg |
| Olympus | https://www.olympus-global.com/shared/images/ci-logo-01.png （只有 PNG） |
| Panasonic | https://www.panasonic.com/content/dam/panasonic/global/en/common/panasonic-plogo-horizontal.svg （LUMIX 页面上没有单独的 LUMIX logo 文件） |
| Pentax | https://www.ricoh-imaging.co.jp/english/products/k-3-3/top/img/logo-pentax-k3iii-h.svg （只保留 PENTAX 字样） |
| Polaroid | https://www.polaroid.com/ （页头内嵌 SVG） |
| Ricoh | https://www.ricoh.com/-/Media/Ricoh/Common/cmn_g_header_footer/img/logo/logo.svg |
| Rollei | https://www.rollei.de/ 页头 Rollei_Logo_white.png （只有 PNG） |
| Sigma | https://www.sigma-global.com/common/images/logo.svg |
| Sony | https://www.sony.net/ （页头内嵌 SVG） |
| Voigtländer | https://www.cosina.co.jp/wp/wp-content/uploads/2021/08/logo-voigtlander.svg |
| Yashica | https://www.yashica.com/ 页头 PNG（只有 PNG） |
| Zeiss | https://www.zeiss.com/etc.clientlibs/zeiss-aem-app/jupiter/clientlibs/jupiter-components.app/resources/assets/icons/symbols/zeiss-logo.svg |

深色画布用的白字版（各品牌文件夹里的 `*-rev` 文件）：Fujifilm、Konica Minolta、Minolta、Konica、Plaubel 是同一文件把黑色字改成白色（彩色部分不变，和 Fujifilm 官方反白用法一致）；Olympus 是把深蓝字改成白色。用「原色」时，深色画布上自动换成这几个版本。

Kodak 的红黄标志在「原色」和「自动」下都保持红黄配色，只有「自定」颜色时换成同形状的单色版 `kodak-mono.svg`。

单色 logo（Sony、Hasselblad、DJI、Rollei、Voigtländer 的官网文件是白色，其他多数是黑色）没有自己的颜色，「原色」和「自动」一样：浅色画布用黑色，深色画布用白色。

`docs/design/mockups/brand-preview.html` 一次展示全部品牌元素：每个 logo 和变体在四种情况（原色 / 自动 × 白底 / 深底）下的样子、同高并排对比、品牌文字的三种样式。

Minolta、Konica 并入 Konica Minolta 后退出相机业务，没有官网，logo 取自维基共享资源。Mamiya、Contax、Bronica、Minolta、Konica、Wista 都来自第三方网站，不是品牌官方文件，正式放进 App 前最好再找更可靠的来源。

## brands.json

每个品牌一项：`id`、`name`（界面上的品牌名）、`text`（{brand} 显示的文字，大小写跟 logo 一致）、`kind`（`mono` 单色字标 / `color` 彩色字标 / `emblem` 标志）、`ratio`（宽高比）、`match`（EXIF 厂商或型号里含这些字就认成这个品牌）、`classic`（经典品牌），以及 `files`：`logo` 主文件，`alt` 另一种样式（Nikon 的标志），`mono` 单色版（Kodak），`dark` 深色画布用的白字版。
