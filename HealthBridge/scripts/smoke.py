#!/usr/bin/env python3
"""Synthetic transport + real stdio MCP smoke; never reads user health data."""
import datetime, hashlib, json, pathlib, select, subprocess, sys, tempfile, uuid
binary = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='healthbridge-smoke-') as tmp:
    root = pathlib.Path(tmp) / 'sync'; db = pathlib.Path(tmp) / 'health.sqlite'
    epoch, dataset = str(uuid.uuid4()), str(uuid.uuid4())
    now = datetime.datetime.now().timestamp()
    day = '2026-09-19'
    records = [
      {'table':'meal_records','key':'1','json':json.dumps({'id':1,'meal_type':'dinner','eaten_at':1789819200,'notes':'SYNTHETIC ONLY','protein_g':30,'calories_kcal':500})},
      {'table':'activity_metrics_daily','key':day,'json':json.dumps({'date':day,'step_count':6500,'hrv_ms':45,'sleep_seconds':25200})},
      {'table':'body_metrics_daily','key':day,'json':json.dumps({'date':day,'weight_kg':80.0})}
    ]
    payload = ''.join(json.dumps(r,sort_keys=True)+'\n' for r in records).encode()
    m={'version':1,'dataset':dataset,'epoch':epoch,'epochStarted':now,'sequence':1,'snapshot':True,'finalSnapshot':True,'historyStart':1758211200,'timeZone':'Asia/Shanghai','generatedAt':now,'count':len(records),'bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest()}
    batch=root/'batches'/f'{epoch}-000000000001';batch.mkdir(parents=True)
    (batch/'records.jsonl').write_bytes(payload);(batch/'manifest.json').write_text(json.dumps(m))
    subprocess.run([binary,'receive','--root',str(root),'--db',str(db)],check=True,capture_output=True)
    assert (root/'receipts'/f'{epoch}-000000000001.json').exists()
    p=subprocess.Popen([binary,'mcp','--db',str(db)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    def request(id,method,params):
        p.stdin.write(json.dumps({'jsonrpc':'2.0','id':id,'method':method,'params':params})+'\n');p.stdin.flush()
        while True:
            if not select.select([p.stdout],[],[],15)[0]:raise RuntimeError('MCP response timeout')
            line=p.stdout.readline()
            if not line:raise RuntimeError('MCP stopped')
            response=json.loads(line)
            if response.get('id')==id:
                assert 'error' not in response,response
                return response['result']
    try:
        request(1,'initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'healthbridge-smoke','version':'1'}})
        p.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n');p.stdin.flush()
        tools=request(2,'tools/list',{})['tools'];assert len(tools)==9
        tests={
          'health_sync_status':{},'health_daily_summary':{'date':day},
          'health_metric_history':{'metric':'weight','from':day,'to':day},
          'health_sleep':{'date':day},'health_workouts':{'from':day,'to':day},
          'health_meals':{'from':day,'to':day},'health_medications':{'from':day,'to':day},
          'health_records':{'category':'meal_records','from':day,'to':day},
          'health_compare':{'metric':'weight','fromA':day,'toA':day,'fromB':day,'toB':day}
        }
        for i,(name,args) in enumerate(tests.items(),10):
            result=request(i,'tools/call',{'name':name,'arguments':args});assert not result.get('isError'),result
            obj=json.loads(result['content'][0]['text'])
            if name=='health_metric_history':assert obj['result']['values'][0]['value']==80
            if name=='health_compare':assert obj['result']['difference']==0
        result=request(99,'tools/call',{'name':'run_sql','arguments':{}});assert result['isError']
        print(json.dumps({'status':'PASS','synthetic':True,'tools':9,'unknownToolRejected':True,'receiptVerified':True}))
    finally:
        p.stdin.close()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
