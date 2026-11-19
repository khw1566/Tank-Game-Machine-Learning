class_name ShotDistribution
extends RefCounted
## Empirical, target-centered hit/near-pass samples. No invented misses or simulated points.

static func collect(data: ReplayData) -> Dictionary:
	var samples := []
	var missing := 0
	var estimated := 0
	for i in data.shots.size():
		var shot: Dictionary = data.shots[i]
		var r: Dictionary = shot.r
		var target := int(shot.target)
		var local: Array = []
		var source := "recorded_local"
		var near: Dictionary = r.get("near_miss", {})
		var kind := "penetration" if r.get("penetrated", false) else "hit"
		if r.get("hit", false):
			local = r.get("entry_local", [])
		else:
			if near.is_empty(): continue
			kind = "near"
			target = -1
			for tank in data.tanks():
				if str(tank.name) == str(near.get("target_name", "")):
					target = int(tank.id)
					break
			local = near.get("local_point", [])
			if local.size() != 3 and target >= 0 and near.get("point", []).size() == 3 and not data.frames.is_empty():
				var pose := data.pose(target, float(near.get("sample_time_s", shot.t)))
				local = TankSpec._v(pose.xform.affine_inverse() * ReplayData.vec3(near.point))
				source = "frame_estimate"
		if local.size() != 3 or target < 0 or target >= data.tanks().size():
			missing += 1
			continue
		var tank: Dictionary = data.tanks()[target]
		var size := ReplayData.vec3(tank.get("hull_size", []))
		if size.x <= 0 or size.y <= 0 or size.z <= 0:
			missing += 1
			continue
		if source == "frame_estimate": estimated += 1
		var point := ReplayData.vec3(local)
		var centered := point - Vector3(0, float(tank.get("hull_bottom_y", 0)) + size.y * 0.5, 0)
		var n := Vector3(centered.x / (size.x * 0.5), centered.y / (size.y * 0.5), centered.z / (size.z * 0.5))
		samples.append({"shot": i + 1, "time_s": shot.t, "target": tank.name, "type": tank.get("tank", "unknown"),
			"episode_uid": str(data.header.get("meta", {}).get("training", {}).get("uid", data.path)),
			"report": data.path.get_base_dir().path_join("report.html"),
			"kind": kind, "friendly": data.tank_team(int(shot.shooter)) == data.tank_team(target),
			"x_m": centered.x, "y_m": centered.y, "z_m": centered.z, "nx": n.x, "ny": n.y, "nz": n.z,
			"miss_distance_m": near.get("miss_distance_m", 0) if kind == "near" else 0,
			"range_m": near.get("range_m", 0) if kind == "near" else r.get("distance_m", 0), "source": source})
	return {"samples": samples, "missing_coordinates": missing, "estimated_coordinates": estimated,
		"shots_total": data.shots.size(), "normalization": "target hull half-width, half-height, half-length; hull center origin"}

static func csv_text(payload: Dictionary) -> String:
	var fields := ["episode_uid", "report", "shot", "time_s", "target", "type", "kind", "friendly", "x_m", "y_m", "z_m", "nx", "ny", "nz", "miss_distance_m", "range_m", "source"]
	var lines := PackedStringArray([",".join(fields)])
	for row in payload.samples:
		var cells := PackedStringArray()
		for key in fields:
			cells.append('"' + str(row.get(key, "")).replace('"', '""') + '"')
		lines.append(",".join(cells))
	return "\n".join(lines) + "\n"

static func html(payload: Dictionary) -> String:
	var json := JSON.stringify(payload).replace("<", "\\u003c")
	return """<section data-dispersion><h2>명중·지근탄 합성 분포</h2>
<p class='note'>각 표적의 위치·차체 방향을 원점으로 정렬했습니다. 차종을 함께 볼 때는 차체 반너비·반높이·반길이를 각각 1로 맞춥니다. 점 하나가 실제 명중 또는 최근접 지근탄 표본 하나입니다.</p>
<div class='filters'><label>표적 차종 <select data-type><option value='all'>전체 · 표준 차체로 합성</option></select></label><label>표본 <select data-kind><option value='all'>명중 + 지근탄</option><option value='hit'>명중만</option><option value='near'>지근탄만</option></select></label><label>범위 <select data-zoom><option value='0'>전체 분포</option><option value='3'>차체 주변 확대 (±3)</option></select></label><label><input type='checkbox' data-friendly> 아군 사격 포함</label></div>
<p class='dispersion-summary' data-summary></p><div class='density-legend'><span><i style='background:#16796c'></i>관통 명중</span><span><i style='background:#bd7a17'></i>비관통 명중</span><span><i style='background:#357abd'></i>지근탄</span><span>옅은 격자색 = 관측 표본 비율 · 점 위에 마우스를 올리면 원본 수치</span></div>
<div class='dispersion-plots'><figure><svg data-front viewBox='0 0 480 470' role='img' aria-label='전차 중심 정면 명중 및 지근탄 분포'></svg><figcaption>정면 투영: 가로 = 차체 좌우, 세로 = 높이. 위쪽이 전차 상부입니다.</figcaption></figure><figure><svg data-top viewBox='0 0 480 470' role='img' aria-label='전차 중심 상부 명중 및 지근탄 분포'></svg><figcaption>상부 투영: 가로 = 차체 좌우, 세로 = 전후. 전차 정면(−Z)은 위쪽입니다.</figcaption></figure></div>
<div class='explanation'><p>격자의 비율은 <b>선택한 명중·지근탄 표본 중 해당 구역에 들어온 비율</b>입니다. 전체 발사탄의 명중 확률이나 앞으로 쏠 탄의 확률 예측이 아닙니다. 전체 리플레이를 남긴 경기만 포함하므로 전체 학습 사격을 대표하는 통계로 해석하면 안 됩니다. 투영도는 입사 방향을 통일한 조준 오차판이 아니라 차체 기준의 3차원 위치를 두 방향에서 본 것입니다.</p><p>지근탄 기록은 표적 중심으로부터 12m 이내에서 포착된 최근접 통과점입니다. 이보다 먼 빗나감과 좌표가 없는 사격은 점을 만들지 않습니다. 이전 기록의 지근탄은 표적 자세를 보간한 추정치일 수 있으며, 해당 점은 흰색 테두리로 표시합니다.</p><p data-quality></p></div>
<div class='actions'><a class='button' href='shot_distribution.csv' download>분포 원자료 CSV</a><a class='button' href='shot_distribution.json' download>분포 원자료 JSON</a></div>
<script type='application/json' data-samples>""" + json + """</script></section>
<script>(()=>{const NS='http://www.w3.org/2000/svg';document.querySelectorAll('[data-dispersion]').forEach(root=>{if(root.dataset.ready)return;root.dataset.ready='1';const data=JSON.parse(root.querySelector('[data-samples]').textContent),sel=root.querySelector('[data-type]');[...new Set(data.samples.map(p=>p.type))].sort().forEach(t=>{const o=document.createElement('option');o.value=t;o.textContent=({tiger1:'티거 I',sherman75:'셔먼 76mm',t34_76:'T-34-85'})[t]||t;sel.append(o)});
function node(svg,tag,attrs,text){const e=document.createElementNS(NS,tag);Object.entries(attrs||{}).forEach(([k,v])=>e.setAttribute(k,v));if(text!=null)e.textContent=text;svg.append(e);return e}
function plot(svg,rows,front){svg.replaceChildren();const a=54,b=430,c=54,d=402;let extent=2.5;rows.forEach(p=>{extent=Math.max(extent,Math.ceil(Math.max(Math.abs(p.nx),Math.abs(front?p.ny:-p.nz))*2.2)/2)});const zoom=Number(root.querySelector('[data-zoom]').value);if(zoom)extent=zoom;const inView=p=>Math.abs(p.nx)<=extent&&Math.abs(front?p.ny:-p.nz)<=extent;const visible=rows.filter(inView);const sx=x=>a+(x+extent)/(2*extent)*(b-a),sy=y=>d-(y+extent)/(2*extent)*(d-c);node(svg,'text',{x:24,y:27,fill:'#17324d','font-size':16,'font-weight':600},front?'정면 · 좌우 / 높이':'상부 · 좌우 / 전후');node(svg,'text',{x:454,y:27,'text-anchor':'end',fill:'#576b80','font-size':10},`범위 밖 ${rows.length-visible.length}점`);const N=20,bins=Array(N*N).fill(0);visible.forEach(p=>{const ix=Math.max(0,Math.min(N-1,Math.floor((p.nx+extent)/(2*extent)*N))),iy=Math.max(0,Math.min(N-1,Math.floor(((front?p.ny:-p.nz)+extent)/(2*extent)*N)));bins[iy*N+ix]++});const peak=Math.max(1,...bins);bins.forEach((n,i)=>{if(!n)return;const ix=i%N,iy=Math.floor(i/N),x=-extent+ix*2*extent/N,y=-extent+(iy+1)*2*extent/N;const rect=node(svg,'rect',{x:sx(x),y:sy(y),width:(b-a)/N,height:(d-c)/N,fill:'#357abd',opacity:.08+.35*n/peak});node(rect,'title',{},`${n} / ${rows.length} 표본 · 관측 비율 ${(100*n/Math.max(1,rows.length)).toFixed(2)}%`)});
for(let i=0;i<=4;i++){const v=-extent+i*extent/2;node(svg,'line',{x1:sx(v),x2:sx(v),y1:c,y2:d,stroke:'#dce5ee'});node(svg,'line',{x1:a,x2:b,y1:sy(v),y2:sy(v),stroke:'#dce5ee'});node(svg,'text',{x:sx(v),y:424,'text-anchor':i===0?'start':i===4?'end':'middle',fill:'#576b80','font-size':11},v.toFixed(1));node(svg,'text',{x:47,y:sy(v)+4,'text-anchor':'end',fill:'#576b80','font-size':11},v.toFixed(1))}
node(svg,'rect',{x:sx(-1),y:sy(1),width:sx(1)-sx(-1),height:sy(-1)-sy(1),fill:'#a9bac8','fill-opacity':.28,stroke:'#6b8194','stroke-width':1.4});if(front){node(svg,'rect',{x:sx(-.67),y:sy(2.1),width:sx(.67)-sx(-.67),height:sy(1)-sy(2.1),fill:'#93a9ba','fill-opacity':.3,stroke:'#6b8194'})}else{node(svg,'rect',{x:sx(-.65),y:sy(.45),width:sx(.65)-sx(-.65),height:sy(-.45)-sy(.45),fill:'#93a9ba','fill-opacity':.3,stroke:'#6b8194'});node(svg,'line',{x1:sx(0),x2:sx(0),y1:sy(.3),y2:sy(1.9),stroke:'#6b8194','stroke-width':4})}node(svg,'line',{x1:sx(0)-6,x2:sx(0)+6,y1:sy(0),y2:sy(0),stroke:'#17324d'});node(svg,'line',{x1:sx(0),x2:sx(0),y1:sy(0)-6,y2:sy(0)+6,stroke:'#17324d'});
visible.forEach(p=>{const dot=node(svg,'circle',{cx:sx(p.nx),cy:sy(front?p.ny:-p.nz),r:p.kind==='near'?3.6:4.2,fill:p.kind==='near'?'#357abd':p.kind==='penetration'?'#16796c':'#bd7a17',opacity:.85,stroke:p.source==='frame_estimate'?'white':'none','stroke-width':1.5});node(dot,'title',{},`#${p.shot} ${p.target} · ${p.kind==='near'?'지근탄':p.kind==='penetration'?'관통 명중':'비관통 명중'} · x ${p.x_m.toFixed(3)}m / y ${p.y_m.toFixed(3)}m / z ${p.z_m.toFixed(3)}m · 사거리 ${Number(p.range_m).toFixed(1)}m · ${p.kind==='near'?'최근접 '+Number(p.miss_distance_m).toFixed(3)+'m · ':''}${p.source==='frame_estimate'?'표적 자세 보간 추정':'기록된 차체 좌표'}`)});node(svg,'text',{x:242,y:451,'text-anchor':'middle',fill:'#576b80','font-size':11},'정규화 좌표 · 차체 중심 0 / 차체 경계 ±1');if(!rows.length)node(svg,'text',{x:242,y:220,'text-anchor':'middle',fill:'#576b80','font-size':14},'선택한 조건에 좌표 표본이 없습니다')}
function draw(){const kind=root.querySelector('[data-kind]').value,include=root.querySelector('[data-friendly]').checked,rows=data.samples.filter(p=>(sel.value==='all'||p.type===sel.value)&&(kind==='all'||(kind==='near'?p.kind==='near':p.kind!=='near'))&&(include||!p.friendly)),hits=rows.filter(p=>p.kind!=='near').length,near=rows.length-hits;root.querySelector('[data-summary]').textContent=`표시 ${rows.length}점 · 명중 ${hits} / 지근탄 ${near} · 표본 수가 작으면 분포를 일반화할 수 없습니다`;root.querySelector('[data-quality]').textContent=`전체 사격 ${data.shots_total}발 · 좌표 누락 ${data.missing_coordinates}건 · 보간 추정 좌표 ${data.estimated_coordinates}건. 아군 사격은 기본 제외합니다.`;plot(root.querySelector('[data-front]'),rows,true);plot(root.querySelector('[data-top]'),rows,false)}root.querySelectorAll('select,input').forEach(el=>el.addEventListener('change',draw));draw()})})();</script>"""
