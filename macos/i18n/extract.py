import re,glob,json,sys
def literals(src):
    """返回 Swift 源码里的字符串字面量，插值替换为 {}，同时记录每个插值的表达式。"""
    i,n=0,len(src)
    while i<n:
        c=src[i]
        if src.startswith("//",i):
            i=src.find("\n",i); i=n if i<0 else i; continue
        if c=='"' and not src.startswith('"""',i):
            j=i+1; out=[]; exprs=[]
            while j<n and src[j]!='"':
                if src[j]=="\\" and j+1<n and src[j+1]=="(":
                    d=1; k=j+2; inner_start=k
                    while d:
                        if src[k]=='"':   # 跳过插值里的字符串
                            k+=1
                            while src[k]!='"':
                                k+= 2 if src[k]=="\\" else 1
                        elif src[k]=="(": d+=1
                        elif src[k]==")": d-=1
                        k+=1
                    exprs.append(src[inner_start:k-1]); out.append("{}"); j=k
                elif src[j]=="\\":
                    out.append(src[j:j+2]); j+=2
                elif src[j]=="\n": break
                else:
                    out.append(src[j]); j+=1
            yield "".join(out), exprs
            i=j+1
        else: i+=1
if __name__=="__main__":
    keys={}
    for f in sorted(glob.glob('*.swift')):
        if f=="ReportView.swift": continue
        for k,ex in literals(open(f).read()):
            if re.search(r'[一-鿿]',k) and "\\\\s" not in k:
                keys.setdefault(k,ex)
    json.dump(keys,open('/tmp/keys2.json','w'),ensure_ascii=False,indent=0)
    print(len(keys))
    for k,e in keys.items(): print(k, "  ##", e if e else "")
