"""거절된 raw graph의 실제 구조 비용을 읽는다. runtime acceptance를 변경하지 않는다."""
from pathlib import Path
import json,hashlib,collections,sys
root=Path(sys.argv[1]).resolve()
p=root/'external-graph.json';raw=p.read_bytes();assert len(raw)<=16*1024*1024
v=json.loads(raw);todo=[(v,0)];values=0;depth=0;container=0
while todo:
 item,d=todo.pop();values+=1;depth=max(depth,d);assert values<=1000000 and d<=512
 if isinstance(item,(list,dict)):
  container=max(container,len(item));todo.extend((x,d+1) for x in (item.values() if isinstance(item,dict) else item))
nodes=[];todo=[(n,str(i),None,0) for i,n in reversed(list(enumerate(v)))];bytype=collections.Counter();propertyids=collections.Counter();samples={};texts=[]
expected={'ALPHA SWIFTUI 731','BRAVO DECLARATIVE 482','CHARLIE BRANCH 263','DELTA BRANCH 914','UIKit witness 596'}
while todo:
 node,path,parent,d=todo.pop();assert len(nodes)<2048 and d<=128 and isinstance(node,dict)
 props=node['properties'];children=node['children'];assert isinstance(props,list) and isinstance(children,list)
 types=[q['attribute'].get('type') for q in props if q['id']==0]
 row=dict(path=path,parentPath=parent,depth=d,children=[path+'/'+str(i) for i in range(len(children))],types=types,propertyIDs=[q['id'] for q in props],nodeKeys=sorted(node))
 nodes.append(row)
 for t in types:bytype[t]+=1;samples.setdefault(t,dict(path=path,properties=props))
 for q in props:propertyids[q['id']]+=1
 stack=[(props,'properties')]
 while stack:
  x,xpath=stack.pop()
  if isinstance(x,str) and x in expected:texts.append(dict(nodePath=path,propertyPath=xpath,value=x))
  elif isinstance(x,dict):stack.extend((y,xpath+'.'+k) for k,y in x.items())
  elif isinstance(x,list):stack.extend((y,xpath+'['+str(i)+']') for i,y in enumerate(x))
 todo.extend((n,path+'/'+str(i),path,d+1) for i,n in reversed(list(enumerate(children))))
result=dict(runtimeAcceptance='REJECTED: structureBudgetExceeded; offline diagnostics do not reopen it',sourceSHA256=hashlib.sha256(raw).hexdigest(),bytes=len(raw),
 rawTopLevel=type(v).__name__,rootCount=len(v),serializedValues=values,maxJSONDepth=depth,maxContainerLength=container,nodeCount=len(nodes),maxDeclarativeDepth=max(n['depth'] for n in nodes),
 propertyIDCounts=dict(propertyids),actualTypeCounts=dict(bytype),exactTextValueOccurrences=texts,nodes=nodes)
(root/'rejected-graph-diagnostics.json').write_text(json.dumps(result,indent=2))
selected={t:row for t,row in samples.items() if t in ['SwiftUI.Text','SwiftUIProbe.ProbeContent','SwiftUIProbe.ProbeUIKit'] or t.startswith('SwiftUI._ShapeView<')}
(root/'observed-property-examples.json').write_text(json.dumps(selected,indent=2))
print(json.dumps({k:result[k] for k in ['rawTopLevel','rootCount','serializedValues','maxJSONDepth','maxContainerLength','nodeCount','maxDeclarativeDepth','propertyIDCounts','exactTextValueOccurrences']},indent=2))
print('TYPES')
for t,n in bytype.items():print(n,t)
