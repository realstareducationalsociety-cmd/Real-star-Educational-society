import fs from 'node:fs'
let p='app/components/MonthlyRegistration.vue',s=fs.readFileSync(p,'utf8')
s=s.replace('  original_fee: number | null','  custom_teacher_share: boolean\n  teacher_share_reason: string\n  sponsored_confirmed: boolean\n  original_fee: number | null')
s=s.replace('const approved = ref(false)',`const approved = ref(false)
const duplicateConfirmed=ref(false),duplicateMatches=ref<any[]>([])
let duplicateVersion=0
watch(()=>[person.first_name,person.last_name,person.phone],async()=>{duplicateConfirmed.value=false;duplicateMatches.value=[];const version=++duplicateVersion;if(!db||mode.value!=='new'||person.first_name.trim().length<2)return;const r=await db.rpc('registration_student_search',{p_query:(person.first_name+' '+person.last_name).trim()});if(version===duplicateVersion&&!r.error)duplicateMatches.value=r.data||[]})
watch(rows,()=>{for(const row of rows.value){if(!row.custom_teacher_share)row.teacher_entitlement=row.agreed_fee===null?null:Math.round(Number(row.agreed_fee)*50)/100;if(Number(row.agreed_fee)<=0||row.discount!==row.agreed_fee)row.sponsored_confirmed=false}},{deep:true})`)
s=s.replace('    original_fee: null, agreed_fee:',"    custom_teacher_share:false, teacher_share_reason:'', sponsored_confirmed:false,\n    original_fee: classes.value.find(c=>c.id===classId)?.default_fee ?? null, agreed_fee:")
s=s.replace('  row.teacher_entitlement = Number(record.teacher_entitlement)',"  row.teacher_entitlement = Number(record.teacher_entitlement)\n  row.custom_teacher_share=record.teacher_share_mode==='custom'||Number(record.teacher_entitlement)!==Math.round(Number(record.agreed_fee??record.base_fee)*50)/100\n  row.teacher_share_reason=record.teacher_share_reason||record.manual_adjustment_reason||''")
s=s.replace("if (!approved.value || rows.value.some(row =>", "if (!approved.value || rows.value.some(row => (row.custom_teacher_share && row.teacher_share_reason.trim().length<4) ||")
s=s.replace('      approved: approved.value,','      approved: approved.value,\n      duplicate_profile_confirmed: duplicateConfirmed.value,')
s=s.replace('<section class="card monthly-registration">','<section id="monthly-registration" class="card monthly-registration">')
s=s.replace('<div class="registration-tabs">',"<h3>{{t('agreements.studentSection')}}</h3>\n        <div class=\"registration-tabs\">")
s=s.replace('<p v-if="loading">',`<div v-if="selected" class="form-grid"><label v-for="field in (['first_name','last_name','guardian_name','phone','guardian_phone','address'] as const)" :key="field">{{t('registration.'+field)}}<input :value="selected[field]||''" readonly/></label></div>
          <h3 v-if="selected">{{t('agreements.historySection')}}</h3><p v-if="loading">`)
s=s.replace('<p>{{record.notes}}</p>',"<p v-if=\"record.start_time_snapshot\">{{t('agreements.schedule')}}: {{timeShort(record.start_time_snapshot)}} – {{timeShort(record.end_time_snapshot)}}</p><p>{{record.notes}}</p>")
s=s.replace('<h3>{{ t(\'registration.selectedMonth\') }}</h3>',`<div v-if="mode==='new' && duplicateMatches.length" class="accent-callout"><p>{{t('agreements.possibleDuplicate')}}</p><button v-for="match in duplicateMatches" :key="match.id" class="btn" type="button" @click="mode='returning';nextTick(()=>choose(match))">{{match.first_name}} {{match.last_name}} · {{match.student_code}}</button><label class="approval-check"><input v-model="duplicateConfirmed" type="checkbox"/>{{t('agreements.distinctPerson')}}</label></div>
        <h3>{{ t('registration.selectedMonth') }}</h3>`)
s=s.replace('<label class="class-search">',"<h3>{{t('agreements.classSection')}}</h3>\n        <label class=\"class-search\">")
s=s.replace("{{ classItem.title }}{{ classItem.teacher?.full_name ? ` — ${classItem.teacher.full_name}` : '' }}","{{ classItem.title }} · {{classItem.teacher?.full_name}} · {{timeShort(classItem.start_time)}}–{{timeShort(classItem.end_time)}} · {{money(classItem.default_fee)}}")
s=s.replace("(['original_fee','agreed_fee','teacher_entitlement'] as const)","(['original_fee','agreed_fee'] as const)")
s=s.replace('<label v-for="field in ([\'original_fee\'', '<h4 class="wide">{{t(\'agreements.tuitionSection\')}}</h4><label v-for="field in ([\'original_fee\'')
s=s.replace('<label v-if="isAdmin">',`<h4 class="wide">{{t('agreements.teacherSection')}}</h4>
            <div class="wide"><p>{{t('agreements.recommendedShare')}}: <strong>{{money(Math.round(fee(row)*50)/100)}}</strong></p><label class="approval-check"><input v-model="row.custom_teacher_share" type="checkbox"/>{{t('agreements.customShare')}}</label></div>
            <label>{{t('registration.teacher_entitlement')}}<input v-model.number="row.teacher_entitlement" :readonly="!row.custom_teacher_share" type="number" min="0" step="0.01" required/></label>
            <label v-if="row.custom_teacher_share">{{t('agreements.customReason')}}<input v-model="row.teacher_share_reason" required minlength="4"/></label>
            <label v-if="fee(row)>0 && row.discount===fee(row)" class="approval-check wide"><input v-model="row.sponsored_confirmed" type="checkbox"/>{{t('agreements.confirmSponsored')}}</label>
            <h4 class="wide">{{t('agreements.initialSection')}}</h4><label v-if="isAdmin">`)
s=s.replace('<dt>{{ t(\'registration.balance_due\') }}</dt>',"<dt>{{t('registration.payment')}}</dt><dd>{{money(row.payment)}}</dd><dt>{{ t('registration.balance_due') }}</dt>")
s=s.replace('<label class="approval-check"><input v-model="approved"',"<h3>{{t('agreements.approvalSection')}}</h3><label class=\"approval-check\"><input v-model=\"approved\"")
s=s.replace("t(mode === 'new' ? 'registration.saveNew' : 'registration.confirm')","t('agreements.confirmRegister')")
s=s.replace('|| !approved || !isAdmin','|| !approved || !isAdmin || (mode===\'new\' && duplicateMatches.length>0 && !duplicateConfirmed)')
fs.writeFileSync(p,s)
// Visible entry points all use MonthlyRegistration.
for(const [file,label] of [['app/pages/index.vue','registerStudent'],['app/pages/enrollments.vue','newRegistration'],['app/pages/students.vue','newRegistration']]){let v=fs.readFileSync(file,'utf8');const at=v.indexOf('>',v.indexOf('<PageTitle'));v=v.slice(0,at+1)+`<NuxtLink v-if="auth.profile.value?.role==='admin'" class="btn primary" to="/enrollments#monthly-registration">{{t('agreements.${label}')}}</NuxtLink>`+v.slice(at+1);fs.writeFileSync(file,v)}
// Extend editor to explicitly approve standard/custom and sponsorship changes.
p='app/components/AgreementEditor.vue';s=fs.readFileSync(p,'utf8').replace("const form=reactive({", "const form=reactive({custom_teacher_share:props.membership.teacher_share_mode==='custom'||Number(props.membership.teacher_entitlement)!==Math.round(Number(props.membership.base_fee)*50)/100,teacher_share_reason:props.membership.teacher_share_reason||'',sponsored_confirmed:props.membership.sponsored_confirmed||false,")
s=s.replace("watch(form,()=>{approved.value=false}","watch(form,()=>{approved.value=false;if(!form.custom_teacher_share)form.teacher_entitlement=Math.round(form.agreed_fee*50)/100;if(form.discount!==form.agreed_fee)form.sponsored_confirmed=false}")
s=s.replace('type="number" min="0"',':readonly="field===\'teacher_entitlement\'&&!form.custom_teacher_share" type="number" min="0"')
s=s.replace('<label>{{t(\'agreements.discountReason\')}}',`<label class="approval"><input v-model="form.custom_teacher_share" type="checkbox"/>{{t('agreements.customShare')}}</label><label v-if="form.custom_teacher_share">{{t('agreements.customReason')}}<input v-model="form.teacher_share_reason" required minlength="4"/></label><label v-if="form.agreed_fee>0&&form.agreed_fee===form.discount" class="approval"><input v-model="form.sponsored_confirmed" type="checkbox"/>{{t('agreements.confirmSponsored')}}</label><label>{{t('agreements.discountReason')}}`)
fs.writeFileSync(p,s)
