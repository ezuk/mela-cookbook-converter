# Dump block-level elements: tag.class | text (truncated)
# Usage: python3 -I dump_blocks.py file1.html[,file2.html...] [width]
import sys, re
from html.parser import HTMLParser
BLOCK={'p','h1','h2','h3','h4','h5','h6','li','div','td','th','img','table','ul','ol','blockquote','figure','figcaption','span'}
class P(HTMLParser):
    def __init__(s): super().__init__(); s.stack=[]; s.out=[]; s.buf=''
    def flush(s):
        t=re.sub(r'\s+',' ',s.buf).strip()
        if t and s.stack: s.out.append((len(s.stack), s.stack[-1], t))
        s.buf=''
    def handle_starttag(s,tag,a):
        a=dict(a)
        if tag=='img': s.flush(); s.out.append((len(s.stack),f"img src={a.get('src')}",'')); return
        if tag in BLOCK and tag!='span': s.flush()
        if tag in BLOCK and tag!='span': s.stack.append(f"{tag}.{a.get('class','')}" + (f"#{a['id']}" if 'id' in a and len(a['id'])<12 else ''))
    def handle_endtag(s,tag):
        if tag in BLOCK and tag!='span':
            s.flush()
            if s.stack: s.stack.pop()
    def handle_data(s,d): s.buf+=d
w=int(sys.argv[2]) if len(sys.argv)>2 else 110
for f in sys.argv[1].split(','):
    p=P(); p.feed(open(f,encoding='utf-8').read()); p.flush()
    print('#####',f)
    for d,tag,t in p.out: print(f"{'  '*min(d,6)}{tag:28.28} | {t[:w]}")
