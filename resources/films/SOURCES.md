# 胶卷图标来源

胶卷名、胶卷盒上的图案和字样是各胶片厂的商标，不在本项目的 GPL 许可范围内。

每个胶片厂一个文件夹（`kodak/`、`fujifilm/`、`ilford/`、`kentmere/`、`cinestill/`、`lomography/`），文件名就是 `films.json` 里的 id。`films.json` 每种胶卷一项：`name`（源图里填的胶卷名，用来匹配）、`id`、`maker`、`process`（冲洗工艺，现在不画在图标上）、`icon`（图标文件）。

还没有图标的胶卷，界面上用胶卷品牌的 logo（Kodak、Fujifilm）或文字代替；用户也可以在「胶卷图标」里导入自己的图标，优先于内置的。

## 扁平图标

各胶片厂文件夹里的 29 个 SVG 是本项目自己画的，按 GPL 发布（上面的胶卷名和品牌名仍是商标），用的是同一个版式：上方是胶卷系列名（大字），感光度在下方统一右对齐，底部色条是品牌名。颜色参考各胶卷盒子的主色，不照搬盒子上的图案。胶卷名仍然是各厂的商标。`docs/design/mockups/film-icons-preview.html` 可以一次看完所有图标。

系列名和感光度的字体，按各盒子上字形的性格挑选开源字体，不用厂商自己的字体。品牌名统一用 Archivo。

| 胶卷 | 系列名 | 感光度 |
|---|---|---|
| Portra 160 / 400 | Jost Light（细几何无衬线） | 同左 |
| Portra 800 | Bodoni Moda，大字距大写 | Bodoni Moda Bold（高反差衬线） |
| Gold 200 | Fraunces Black（粗衬线） | Jost Light |
| Ektar 100 | Barlow Condensed Light | 同左 |
| ProImage 100 | Barlow Condensed Medium | 同左 |
| ColorPlus 200 | Archivo Bold | 同左 |
| UltraMax 400 | Archivo Black Italic | 同左 |
| Ektachrome E100 | Source Sans 3 SemiBold | Michroma 加粗（宽扁体） |
| T-Max | Archivo Expanded，大字距 | Montserrat Black |
| Tri-X | Archivo Expanded，大字距 | Montserrat ExtraBold，加立体阴影 |
| Vision3 | Archivo，大字距 | Barlow Condensed ExtraBold |
| Velvia 50 | Jost | Barlow Condensed Bold |
| Provia 100F、Pro 400H | Barlow Condensed Bold | 同左 |
| Fujifilm 400、C200、Lomography | Archivo，大字距 | Archivo Bold / Black |
| HP5、FP4、Delta | Archivo Black | 同左 |
| Kentmere Pan 100 | Archivo Black | Jost Light |
| CineStill | Archivo Expanded Italic | Jost 细体 |

这些字体都来自 [google/fonts](https://github.com/google/fonts)，都是 SIL Open Font License。文字已经转成路径，SVG 里不含字体，也不依赖系统字体。

和盒子对照后改过的颜色：ProImage 100 改成黄色加黑色；HP5、FP4、Delta 改成 Ilford 的白盒加黑色品牌条，字分别是黑、蓝、紫（Delta 3200 原来误用了红色）；Kentmere 改成蓝色加白色品牌条。

Tri-X 数字的立体阴影是 6 份平移过的路径合在一条 `path` 里，不用 `<use>`：内置 SVG 要在 App 的受限 SVG 格式（D-09）之内。

## 重新生成

`generator/flat_films.py` 是生成脚本，`generator/textpath.py` 负责排版和转路径（HarfBuzz 排字，含字距调整）。它把 SVG 写进各胶片厂的文件夹，并重写 `films.json`；之后运行 `python3 resources/generate_swift.py` 把改动生成进程序。需要 `pip install fonttools uharfbuzz`，并把上表的字体文件放进一个文件夹，然后在 `resources/films` 里运行：

```bash
FONT_DIR=<字体文件夹> python3 generator/flat_films.py .
```
