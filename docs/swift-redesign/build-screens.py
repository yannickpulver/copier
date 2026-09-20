#!/usr/bin/env python3
"""Turn the canvas artboards in canvas/ into standalone HTML in screens/.

Run from this folder: python3 build-screens.py
"""
import glob
import os
import re

SRC = "canvas"
OUT = "screens"
THEME_SCRIPT = """<script>
// follow the system appearance; add ?dark or ?light to force one
var q=location.search,w=document.getElementById("window");
if(q==="?dark"||(q!=="?light"&&matchMedia("(prefers-color-scheme: dark)").matches))w.className="dark";
</script>
</body>"""

os.makedirs(OUT, exist_ok=True)
for path in sorted(glob.glob(SRC + "/*.dc.html")):
    html = open(path).read()
    html = html.replace(
        '<script src="./support.js"></script>\n',
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n',
    )
    html = re.sub(r'<script type="text/x-dc".*?</script>\n?', "", html, flags=re.S)
    style = re.search(r"<helmet>\s*(<style>.*?</style>)\s*</helmet>", html, re.S).group(1)
    style = style.replace(
        "body{margin:0;",
        "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#C9CDD4;",
    )
    style = style.replace(
        "</style>", "@media (prefers-color-scheme: dark){body{background:#0F1012}}\n</style>"
    )
    html = re.sub(r"<helmet>.*?</helmet>\n?", "", html, flags=re.S)
    html = html.replace("</head>", style + "\n</head>")
    html = html.replace("<x-dc>\n", "").replace("</x-dc>\n", "")
    html = html.replace('class="{{theme}}"', 'class="light" id="window"')
    html = html.replace('defaultChecked="{{ true }}"', "checked").replace("defaultValue=", "value=")
    html = html.replace('.dc.html"', '.html"')
    html = html.replace("</body>", THEME_SCRIPT)
    assert "{{" not in html, path
    name = os.path.basename(path).replace(".dc.html", ".html")
    open(os.path.join(OUT, name), "w").write(html)
    print(name)
