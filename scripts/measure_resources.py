#!/usr/bin/env python3
"""Sample only the explicitly requested PIDs, with CPU time deltas and RSS."""
import argparse,datetime,json,pathlib,statistics,subprocess,time

# --- Explicit process sampling ---

def cpu_seconds(value):
    """Convert ps CPU time from minutes or hours notation to seconds."""
    parts=value.split(':')
    if len(parts)==2: return int(parts[0])*60+float(parts[1])
    return int(parts[0])*3600+int(parts[1])*60+float(parts[2])

def sample(pid):
    """Read one requested process's CPU time and RSS, with a monotonic sample timestamp."""
    value=subprocess.check_output(['/bin/ps','-p',str(pid),'-o','pid=,rss=,time=,%cpu='],text=True).split()
    return dict(pid=int(value[0]),rss_mib=int(value[1])/1024,cpu_seconds=cpu_seconds(value[2]),ps_cpu_percent=float(value[3]),monotonic=time.monotonic())

# --- Bounded measurement and report output ---

def main():
    """Sample explicit PIDs for a bounded duration and write raw records and resource summaries."""
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pid',type=int,action='append',required=True)
    p.add_argument('--duration',type=float,default=20)
    p.add_argument('--interval',type=float,default=1)
    p.add_argument('--label',required=True)
    p.add_argument('--output',type=pathlib.Path,required=True)
    args=p.parse_args()
    records={pid:[] for pid in args.pid}; start=time.monotonic()
    while True:
        for pid in args.pid:
            try: records[pid].append(sample(pid))
            except subprocess.CalledProcessError: pass
        if time.monotonic()-start>=args.duration: break
        time.sleep(min(args.interval,max(0,args.duration-(time.monotonic()-start))))
    summaries={}
    for pid,values in records.items():
        if len(values)<2: summaries[pid]={'error':'process did not remain alive'}; continue
        elapsed=values[-1]['monotonic']-values[0]['monotonic']
        delta=values[-1]['cpu_seconds']-values[0]['cpu_seconds']
        summaries[pid]=dict(samples=len(values),elapsed_seconds=round(elapsed,3),
          average_cpu_percent_one_core=round(100*delta/elapsed,3),cpu_time_delta_seconds=round(delta,3),
          rss_mib_mean=round(statistics.mean(v['rss_mib'] for v in values),2),
          rss_mib_max=round(max(v['rss_mib'] for v in values),2))
    report=dict(label=args.label,timestamp=datetime.datetime.now().astimezone().isoformat(),
                scope='Explicit local PIDs; no claim about active remote streaming unless label states it.',summary=summaries,samples=records)
    args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'label':args.label,'summary':summaries},indent=2))

if __name__=='__main__': main()
