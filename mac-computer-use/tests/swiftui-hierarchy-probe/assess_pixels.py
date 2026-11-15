"""원본 PNG를 보존하고 같은 캡처의 고정 ROI와 색·alpha를 대조한다. Pillow가 필요하다."""
from pathlib import Path
import base64,hashlib,json,math,sys
from PIL import Image,ImageChops,ImageStat

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def assess(folder):
 folder=Path(folder);a=json.loads((folder/'association.json').read_text());o=json.loads((folder/'oracle-before.json').read_text());post=json.loads((folder/'oracle-after.json').read_text())
 assert a['pid']==o['pid']==post['pid'] and a['sceneID']==o['sceneID']==post['sceneID'] and o['branch']==post['branch']
 assert a['scale']==o['scale']==3 and a['orientation']==o['orientation']==1 and a['fixedSpaceOrigin']==[0,0]
 assert a['B']['drawHierarchyReturned'] and a['B']['representation']=='hostingSubtreeComposite' and a['hostingAssociationRevalidated']
 raw=json.loads((folder/'A-hierarchy.json').read_text());matches=[]
 def visit(v):
  if isinstance(v,dict):
   if v.get('objectID')==a['hostingAddress'] and v.get('className')==a['hostingClass']:matches.append(v)
   for x in v.values():visit(x)
  elif isinstance(v,list):
   for x in v:visit(x)
 visit(raw);assert len(matches)==1
 props=[p for p in matches[0]['properties'] if p.get('propertyName')=='snapshotImage'];assert len(props)==1
 value=props[0]['propertyValue'];png=base64.b64decode(value['imageData'],validate=True);assert png[:8]==b'\x89PNG\r\n\x1a\n'
 (folder/'A-hosting-snapshot.png').write_bytes(png)
 paths=dict(A=folder/'A-hosting-snapshot.png',B=folder/'B-hosting-composite.png',reference=folder/'independent-screen.png')
 images={k:Image.open(p).convert('RGBA') for k,p in paths.items()};assert all(list(i.size)==a['pixelSize'] for i in images.values())
 result=dict(captureID=a['captureID'],hostingNodeToken=a['hostingNodeToken'],target=dict(pid=a['pid'],start=a['start']),sceneID=a['sceneID'],branch=o['branch'],
  scale=3,orientation='portrait upright, top-left PNG coordinates',coordinateTransform='UIKit global points multiplied by 3; hosting fixed-space origin is (0,0)',
  sourceHashes={k:sha(v) for k,v in paths.items()},originalPixelsPreserved=True,
  comparison='B is one hostingSubtreeComposite; A is current snapshotImage with independently measured descendant coverage',
  thresholdDerivation='At identical integer pixel coordinates in settled static content, allow at most one 8-bit code value of quantization per channel. Each interior opacity bound is 0.5 / (255 * (1 - sourceChannel)) plus 0.000001, from half-code quantization. The opaque rectangle red contrast is 38.25, not the circle minimum 89.25 minimum contrast. No antialias contour exclusion or fitted alignment.',
  threshold=dict(maxChannelDelta=1,apparentOpacityError='per-channel half-code / source-white contrast'),rois={})
 for name,rect in o['rois'].items():
  box=tuple(round(v*3) for v in (rect[0],rect[1],rect[0]+rect[2],rect[1]+rect[3])); ref=images['reference'].crop(box);row=dict(points=rect,pixelBox=box,pixelCount=ref.width*ref.height)
  for k in ['A','B']:
   im=images[k].crop(box);diff=ImageChops.difference(im,ref);ext=diff.getextrema();pixels=list(im.get_flattened_data());row[k]=dict(maxChannelDelta=max(v[1] for v in ext),meanAbsChannelDelta=ImageStat.Stat(diff).mean,nonWhitePixels=sum(min(p[:3])<240 for p in pixels),alphaRange=im.getextrema()[3])
  row['referenceNonWhitePixels']=sum(min(p[:3])<240 for p in ref.get_flattened_data());row['BMatchesReference']=row['B']['maxChannelDelta']<=1
  assert row['referenceNonWhitePixels']>100
  result['rois'][name]=row
 # Use fixed geometric interior patches, not detected pixel bounding boxes.
 for name,source,opacity in [('rectangle',[.85,.15,.2],1),('circle',[.1,.65,.3],.65)]:
  x,y,w,h=o['rois'][name];cx,cy=(x+w/2)*3,(y+h/2)*3;box=(round(cx-12),round(cy-12),round(cx+12),round(cy+12))
  reference=ImageStat.Stat(images['reference'].crop(box)).median[:3];actual=ImageStat.Stat(images['B'].crop(box)).median[:3]
  expected=[round((c*opacity+1-opacity)*255) for c in source]
  inferred=[(actual[i]-255)/(source[i]*255-255) for i in range(3)]
  result['rois'][name]['interior']=dict(pixelBox=box,referenceMedianRGB=reference,BMedianRGB=actual,expectedSRGB=expected,sourceRGB=source,expectedOpacity=opacity,inferredApparentOpacity=inferred,quantizationOpacityBounds=[.5/(255*(1-c))+.000001 for c in source])
  assert max(abs(actual[i]-expected[i]) for i in range(3))<=1
  assert all(abs(v-opacity)<=.5/(255*(1-c))+.000001 for v,c in zip(inferred,source))
 result['BPixelQualified']=all(r['BMatchesReference'] for r in result['rois'].values())
 result['AIncludesTextAndShape']=all(result['rois'][k]['A']['nonWhitePixels']>100 for k in ['title','subtitle','rectangle','circle'])
 result['AIncludesRepresentable']=result['rois']['representable']['A']['nonWhitePixels']>100
 (folder/'pixel-assessment.json').write_text(json.dumps(result,indent=2))
 print(json.dumps({k:result[k] for k in ['captureID','BPixelQualified','AIncludesTextAndShape','AIncludesRepresentable']}))
 return result
if __name__=='__main__':assess(sys.argv[1])
