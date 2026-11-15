async function runProcedure(){
 const name=document.getElementById('proc-name').value;
 const output=document.getElementById('proc-result');
 let params;
 try{params=JSON.parse(document.getElementById('proc-params').value||'{}');if(!params||Array.isArray(params)||typeof params!=='object')throw new Error('Tham số phải là JSON object.');}
 catch(e){output.textContent='JSON không hợp lệ: '+e.message;return;}
 output.textContent='Đang thực thi '+name+'…';
 try{
  const res=await fetch('/api/procedures/'+encodeURIComponent(name),{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({params})});
  const data=await res.json();
  output.textContent=JSON.stringify(data,null,2);
 }catch(e){output.textContent='Lỗi gọi API: '+e.message;}
}
fetch('/api/health').then(r=>r.json()).then(d=>{
 const el=document.getElementById('db-status'); if(el){el.textContent=d.ok?'Đã kết nối':'Chưa kết nối';el.className=d.ok?'good':'bad';}
}).catch(()=>{const el=document.getElementById('db-status');if(el)el.textContent='Chưa kết nối';});

document.querySelectorAll('.business-form').forEach(form=>{
 form.addEventListener('submit',async event=>{
  event.preventDefault();
  const output=form.querySelector('.form-result');
  const values=Object.fromEntries(new FormData(form).entries());
  output.textContent='Đang lưu dữ liệu…';
  try{
   const response=await fetch(`/api/modules/${encodeURIComponent(form.dataset.module)}/save`,{
    method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({section:Number(form.dataset.section),values})
   });
   const data=await response.json();
   output.textContent=data.ok ? `${data.message}\n${JSON.stringify(data.result_sets,null,2)}` : `Không thể lưu: ${data.error||'Lỗi không xác định'}`;
   if(data.ok) setTimeout(()=>location.reload(),900);
  }catch(error){output.textContent='Lỗi kết nối: '+error.message;}
 });
});

async function deleteRecord(moduleKey,section,id){
 if(!confirm(`Bạn chắc chắn muốn xóa bản ghi ID ${id}? Nếu dữ liệu đã phát sinh liên kết, SQL Server sẽ từ chối.`)) return;
 try{
  const response=await fetch(`/api/modules/${encodeURIComponent(moduleKey)}/delete`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({section,id})});
  const data=await response.json();
  if(!data.ok){alert('Không thể xóa: '+(data.error||'Lỗi không xác định'));return;}
  alert(data.message);location.reload();
 }catch(error){alert('Lỗi kết nối: '+error.message);}
}

document.querySelectorAll('.workflow-form').forEach(form=>{
 form.addEventListener('submit',async event=>{
  event.preventDefault();
  const output=form.querySelector('.workflow-result');
  const values=Object.fromEntries(new FormData(form).entries());
  if(form.dataset.module==='transformations' && form.dataset.action==='apply'){
   if(!confirm('Bạn đã xem Preview đúng với danh sách RawId, phương pháp và tham số này chưa? Apply sẽ cập nhật dữ liệu và ghi Audit Log không thể sửa/xóa.')) return;
  }
  if(form.dataset.module==='saving-plans' && ['delete_plan','delete_solution'].includes(form.dataset.action)){
   if(!confirm('Xác nhận xóa bản ghi này? Thao tác không thể tự hoàn tác.')) return;
  }
  if(form.dataset.module==='saving-plans' && form.dataset.action==='set_plan_status'){
   if(!confirm('Xác nhận thay đổi trạng thái kế hoạch?')) return;
  }
  output.textContent='Đang thực hiện quy trình…';
  try{
   const response=await fetch(`/api/workflows/${encodeURIComponent(form.dataset.module)}/${encodeURIComponent(form.dataset.action)}`,{
    method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({values})
   });
   const data=await response.json();
   output.textContent=data.ok ? `${data.message}\n${JSON.stringify(data.result_sets,null,2)}` : `Không thể thực hiện: ${data.error||'Lỗi không xác định'}`;
   if(data.ok && form.dataset.module==='kpi' && form.dataset.action==='series') renderKpiSeries(form, (data.result_sets||[])[0]||[]);
   if(data.ok && !['filter','filter_alerts','series','preview','audit_filter','filter_plans','list_solutions','history'].includes(form.dataset.action)) setTimeout(()=>location.reload(),1300);
  }catch(error){output.textContent='Lỗi kết nối: '+error.message;}
 });
});


function renderKpiSeries(form, rows){
 const host=form.querySelector('.workflow-chart');
 if(!host) return;
 host.replaceChildren();
 if(!rows.length){host.hidden=true;return;}
 const keys=[['ActualValue','Thực tế','actual'],['ExpectedValue','Baseline kỳ vọng','expected'],['TargetValue','Mục tiêu','target']];
 const values=rows.flatMap(r=>keys.map(k=>r[k[0]]).filter(v=>v!==null && v!==undefined && Number.isFinite(Number(v))).map(Number));
 if(!values.length){host.hidden=true;return;}
 const min=Math.min(0,...values), max=Math.max(...values), span=(max-min)||1;
 const W=920,H=300,L=54,R=20,T=24,B=42, iw=W-L-R, ih=H-T-B;
 const ns='http://www.w3.org/2000/svg';
 const svg=document.createElementNS(ns,'svg'); svg.setAttribute('viewBox',`0 0 ${W} ${H}`); svg.setAttribute('role','img'); svg.setAttribute('aria-label','Biểu đồ so sánh thực tế, Baseline và mục tiêu');
 const make=(tag,attrs,parent=svg)=>{const el=document.createElementNS(ns,tag);Object.entries(attrs).forEach(([k,v])=>el.setAttribute(k,String(v)));parent.appendChild(el);return el;};
 for(let i=0;i<=4;i++){const y=T+ih*i/4;make('line',{x1:L,y1:y,x2:W-R,y2:y,class:'chart-grid'});const tx=make('text',{x:L-8,y:y+4,'text-anchor':'end',class:'chart-axis'});tx.textContent=(max-(span*i/4)).toFixed(1);}
 const xAt=i=>L+(rows.length===1?iw/2:iw*i/(rows.length-1));
 const yAt=v=>T+ih-(Number(v)-min)/span*ih;
 rows.forEach((r,i)=>{if(i===0||i===rows.length-1||i%Math.max(1,Math.ceil(rows.length/7))===0){const tx=make('text',{x:xAt(i),y:H-14,'text-anchor':'middle',class:'chart-axis'});tx.textContent=String(r.DayDate||'').slice(5,10);}});
 keys.forEach(([key,label,cls])=>{
  const pts=rows.map((r,i)=>r[key]===null||r[key]===undefined?null:`${xAt(i)},${yAt(r[key])}`).filter(Boolean);
  if(pts.length){make('polyline',{points:pts.join(' '),class:`chart-line ${cls}`,'fill':'none'});}
 });
 const legend=make('g',{});
 keys.forEach(([key,label,cls],i)=>{const x=L+i*190;make('line',{x1:x,y1:12,x2:x+26,y2:12,class:`chart-line ${cls}`},legend);const t=make('text',{x:x+33,y:16,class:'chart-legend'},legend);t.textContent=label;});
 host.appendChild(svg);host.hidden=false;
}

// UC10: xuất báo cáo; phản hồi nhị phân được tải xuống dưới dạng tệp.
const exportForm=document.getElementById('export-report');
if(exportForm){exportForm.addEventListener('submit',async ev=>{
 ev.preventDefault(); const out=document.getElementById('export-result'); const values=Object.fromEntries(new FormData(exportForm).entries());
 const topForm=document.querySelector('form[action="/m/dashboard"]'); if(topForm){const f=Object.fromEntries(new FormData(topForm).entries());values.BuildingId=f.building_id||'';values.EnergyTypeId=f.energy_id||'';}
 out.textContent='Đang tạo báo cáo từ dữ liệu đạt điều kiện…';
 try{const res=await fetch('/api/reports/export',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({values})});
  if(!res.ok){let d={};try{d=await res.json()}catch{};throw new Error(d.error||'Không thể xuất báo cáo.');}
  const blob=await res.blob();const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=(res.headers.get('content-disposition')||'').match(/filename="?([^";]+)"?/i)?.[1]||'EVN03_Report';document.body.appendChild(a);a.click();a.remove();URL.revokeObjectURL(url);out.textContent='Đã tạo và tải báo cáo. Lịch sử xuất được ghi vào ReportExports.';
 }catch(e){out.textContent='Lỗi: '+e.message;}
});}

let selectedUser=null;
function pickUser(u,row){selectedUser=u;const f=document.getElementById('user-form');if(!f)return;
f.elements.UserId.value=u.UserId;f.elements.Username.value=u.Username;f.elements.Username.readOnly=true;f.elements.FullName.value=u.FullName;f.elements.Email.value=u.Email;f.elements.RoleId.value=u.RoleId;
document.getElementById('user-save').textContent='Cập nhật tài khoản';document.querySelectorAll('#users-table tbody tr').forEach(tr=>tr.classList.remove('user-row-selected'));row?.classList?.add('user-row-selected');
}
function clearUserForm(){selectedUser=null;const f=document.getElementById('user-form');if(!f)return;f.reset();f.elements.UserId.value='';f.elements.Username.readOnly=false;document.getElementById('user-save').textContent='Tạo tài khoản';document.getElementById('user-result').textContent='Nhập thông tin để tạo tài khoản mới.';}
async function postUser(action,values){const r=await fetch('/api/users/'+action,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({values})});const d=await r.json();if(!r.ok||!d.ok)throw new Error(d.error||'Yêu cầu không thành công');return d;}
const userForm=document.getElementById('user-form');if(userForm){userForm.addEventListener('submit',async e=>{e.preventDefault();const out=document.getElementById('user-result');const v=Object.fromEntries(new FormData(userForm).entries());const action=v.UserId?'update':'create';out.textContent='Đang xử lý…';try{const d=await postUser(action,v);let extra='';const token=d.result_sets?.[0]?.[0]?.ActivationToken;if(token)extra='\nMã kích hoạt (demo): '+token+' — thư đã được đưa vào EmailOutbox.';out.textContent=d.message+extra;setTimeout(()=>location.reload(),1200);}catch(err){out.textContent='Lỗi: '+err.message;}});}
async function userAction(action,status){if(!selectedUser){alert('Vui lòng chọn tài khoản trong danh sách.');return;}if(!confirm(action==='delete'?'Xóa tài khoản này? SQL sẽ từ chối nếu tài khoản đã phát sinh dữ liệu.':action==='reset'?'Đặt lại mật khẩu và tạo mã kích hoạt mới?':`Xác nhận chuyển trạng thái thành ${status}?`))return;const out=document.getElementById('user-result');try{const d=await postUser(action,{UserId:selectedUser.UserId,Status:status});const token=d.result_sets?.[0]?.[0]?.ActivationToken;out.textContent=d.message+(token?'\nMã kích hoạt mới (demo): '+token:'');setTimeout(()=>location.reload(),1200);}catch(e){out.textContent='Lỗi: '+e.message;}}
function filterUsers(){const q=(document.getElementById('user-search')?.value||'').toLowerCase();document.querySelectorAll('#users-table tbody tr[data-search]').forEach(tr=>tr.hidden=!tr.dataset.search.includes(q));}
async function loadPermissions(){const sel=document.getElementById('perm-role');if(!sel)return;const body=document.querySelector('#perm-table tbody');body.innerHTML='<tr><td colspan="4">Đang tải…</td></tr>';try{const r=await fetch('/api/roles/'+sel.value+'/permissions');const d=await r.json();if(!d.ok)throw new Error(d.error);body.innerHTML='';d.rows.forEach(row=>{const tr=document.createElement('tr');tr.innerHTML=`<td>${escapeHtml(row.PermissionCode)}</td><td>${escapeHtml(row.PermissionName)}</td><td class="perm-check"><input type="checkbox" data-code="${escapeHtml(row.PermissionCode)}" data-kind="view" ${row.CanView?'checked':''}></td><td class="perm-check"><input type="checkbox" data-code="${escapeHtml(row.PermissionCode)}" data-kind="edit" ${row.CanEdit?'checked':''}></td>`;body.appendChild(tr);});body.querySelectorAll('input[data-kind="edit"]').forEach(cb=>cb.addEventListener('change',()=>{if(cb.checked)body.querySelector(`input[data-code="${cb.dataset.code}"][data-kind="view"]`).checked=true;}));}catch(e){body.innerHTML=`<tr><td colspan="4">${escapeHtml(e.message)}</td></tr>`;}}
function escapeHtml(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
const roleSelect=document.getElementById('perm-role');if(roleSelect){roleSelect.addEventListener('change',loadPermissions);loadPermissions();}
async function savePermissions(){const rid=roleSelect?.value;if(!rid)return;const items=[];document.querySelectorAll('#perm-table tbody tr').forEach(tr=>{const v=tr.querySelector('input[data-kind="view"]');const e=tr.querySelector('input[data-kind="edit"]');if(v&&e)items.push({PermissionCode:v.dataset.code,CanView:v.checked||e.checked,CanEdit:e.checked});});const out=document.getElementById('perm-result');try{const d=await postUser('permissions',{RoleId:rid,Items:items});out.textContent=d.message;}catch(e){out.textContent='Lỗi: '+e.message;}}
function filterMail(){const st=document.getElementById('mail-filter')?.value||'';document.querySelectorAll('#mail-table tbody tr[data-status]').forEach(tr=>tr.hidden=!!st&&tr.dataset.status!==st);}
function showMail(m){document.getElementById('mail-body').textContent=`Đến: ${m.ToEmail}\nTên: ${m.ToName||''}\nTiêu đề: ${m.Subject}\nTrạng thái: ${m.Status}\nLỗi: ${m.ErrorMessage||'—'}\n\n${m.Body||''}`;}
