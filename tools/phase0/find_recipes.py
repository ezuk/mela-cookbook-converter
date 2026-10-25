# Phase 0 prototype: code-only recipe finder over an unzipped ePub.
# Usage: python3 -I find_recipes.py <unzipped-epub-dir> [-v]
# Finds ingredient runs, learns the book's recipe-title class from the blocks
# just before them, splits the book at those titles, and scores the result
# against the book's own contents as an answer key. See docs/reference-books.md.
import sys, re, os, collections, xml.etree.ElementTree as ET
from html.parser import HTMLParser
root=sys.argv[1]; verbose='-v' in sys.argv
BLOCK={'p','h1','h2','h3','h4','h5','h6','li','div','td','th','figcaption','blockquote'}
class P(HTMLParser):
    def __init__(s,href): super().__init__(); s.href=href; s.stack=[]; s.out=[]; s.buf=''; s.ids=[]; s.imgs=[]
    def flush(s):
        t=re.sub(r'\s+',' ',s.buf).strip()
        if (t or s.imgs) and s.stack:
            tag,cls=s.stack[-1]; s.out.append(dict(file=s.href,tag=tag,cls=cls,text=t,ids=s.ids,imgs=s.imgs))
        s.buf=''; s.ids=[]; s.imgs=[]
    def handle_starttag(s,tag,a):
        a=dict(a)
        if 'id' in a: s.ids.append(a['id'])
        if tag=='img': s.imgs.append(a.get('src'))
        if tag=='br': s.buf+=' '
        if tag in BLOCK: s.flush(); s.stack.append((tag,a.get('class','')))
    def handle_endtag(s,tag):
        if tag in BLOCK:
            s.flush()
            if s.stack: s.stack.pop()
    def handle_data(s,d): s.buf+=d
opf=ET.parse(os.path.join(root,'content.opf')); O='{http://www.idpf.org/2007/opf}'
man={i.get('id'):i.get('href') for i in opf.iter(O+'item')}
spine=[man[i.get('idref')] for i in opf.iter(O+'itemref')]
blocks=[]
for href in spine:
    p=P(href); p.feed(open(os.path.join(root,href),encoding='utf-8').read()); p.flush()
    blocks+= [b for b in p.out if b['text'] or b['imgs']]
for i,b in enumerate(blocks): b['i']=i
FR='½¼¾⅓⅔⅛⅜⅝⅞'
QTY=re.compile(r'^(\d|['+FR+r']|a pinch|pinch|one |two |three |four |half )',re.I)
UNIT=re.compile(r'\b(cups?|tablespoons?|teaspoons?|tbsp|tsp|ounces?|oz|pounds?|lb|grams?|g|kg|ml|liters?|cloves?|cans?|sticks?|large|medium|small)\b',re.I)
STEP=re.compile(r'^\d{1,2}\s+[A-Z]')
def ingr(b): t=b['text']; return len(t)<200 and not STEP.match(t) and (QTY.match(t) is not None or (UNIT.search(t) is not None and len(t)<90))
# 1. ingredient runs: >=3 consecutive same-class blocks, >=60% ingredient-like
runs=[]; i=0
while i<len(blocks):
    j=i
    while j<len(blocks) and blocks[j]['text'] and (blocks[j]['cls']==blocks[i]['cls'] or (ingr(blocks[j]) and ingr(blocks[j-1] if j>i else blocks[j]))) and not STEP.match(blocks[j]['text']): j+=1
    seg=blocks[i:j]
    if len(seg)>=3 and sum(map(ingr,seg))/len(seg)>=0.6: runs.append((i,j))
    i=max(j,i+1)
# 2. learn title class: nearest preceding short, non-numeric, non-ingredient block before each run
cand=collections.Counter()
def back(i,lim=25):
    for k in range(i-1,max(-1,i-lim),-1):
        b=blocks[k]; t=b['text']
        if t and len(t)<80 and not re.match(r'^[\d'+FR+']',t) and not ingr(b) and not t.endswith(':') and not re.search(r'time|serves|yield|makes',t,re.I):
            yield k
for (a,_) in runs:
    for k in list(back(a))[:4]: cand[(blocks[k]['tag'],blocks[k]['cls'])]+=1
# score classes by how many runs they precede, penalize classes that are very common overall
total=collections.Counter((b['tag'],b['cls']) for b in blocks)
score={c:n*n/total[c] for c,n in cand.items()}
tcls=max(score,key=score.get)
# 3. recipes: title-class block followed (within window) by an ingredient run before the next title
titles=[b['i'] for b in blocks if (b['tag'],b['cls'])==tcls and b['text']]
recipes=[]
for n,t in enumerate(titles):
    end=titles[n+1] if n+1<len(titles) else len(blocks)
    r=[x for x in runs if t<x[0]<end]
    if r: recipes.append(dict(title=blocks[t]['text'],start=t,end=end,runs=len(r),steps=sum(1 for b in blocks[t:end] if STEP.match(b['text']))))
orphans=[x for x in runs if not any(r['start']<x[0]<r['end'] for r in recipes)]
# answer keys: ToC leaves + internal contents links
ns={'n':'http://www.daisy.org/z3986/2005/ncx/'}
toc=[]
def walk(e,d):
    for np in e.findall('n:navPoint',ns):
        kids=np.findall('n:navPoint',ns)
        if not kids and d>0: toc.append(np.find('n:navLabel/n:text',ns).text)
        walk(np,d+1)
walk(ET.parse(os.path.join(root,'toc.ncx')).find('n:navMap',ns),0)
norm=lambda s: re.sub(r'[^a-z0-9]','',s.lower().replace('&','and'))
found={norm(r['title']) for r in recipes}
print(f"blocks={len(blocks)} ingredient_runs={len(runs)} title_class={tcls} recipes={len(recipes)} orphan_runs={len(orphans)} with_steps={sum(1 for r in recipes if r['steps'])}")
# Answer key for chapter-only ToCs: Cook It in Cast Iron's in-book chapter contents class.
links=[b['text'] for b in blocks if b['cls'] in ('toc_chap',)]
if links: toc=links
if toc:
    hit=[t for t in toc if norm(t) in found]
    print(f"toc_leaves={len(toc)} matched={len(hit)}")
    if verbose: print('  toc not found:', [t for t in toc if norm(t) not in found][:40])
if verbose:
    for r in recipes[:12]: print('  ',r)
    print('  orphans:', [blocks[a]['text'][:50] for a,_ in orphans[:10]])
