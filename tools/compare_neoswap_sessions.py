#!/usr/bin/env python3
"""Compare one explicit baseline session with one research session from JSONL logs.

Kernel faults, process footprint and NeoSwap restorations are separate metrics.
One-second FPS samples cannot establish per-frame frametime or stutter counts.
"""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import re
import statistics


def read_rows(paths):
    rows=[]
    for path in paths:
        lines=Path(path).read_text().splitlines()
        for number,line in enumerate(lines,1):
            if not line.strip():
                continue
            try:
                value=json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f'Incomplete log: {path}:{number}') from error
            if not isinstance(value,dict):
                raise ValueError(f'Invalid log record: {path}:{number}')
            rows.append(value)
    # Rotated/current files and overlapping exports may be supplied in any order.
    unique={json.dumps(row,sort_keys=True):row for row in rows}
    return sorted(unique.values(),key=lambda row:row.get('timestamp',0))


def number(value):
    return isinstance(value,(int,float)) and not isinstance(value,bool) and math.isfinite(value)


def values(rows,key):
    return [row[key] for row in rows if number(row.get(key))]


def percentile(items,q):
    if not items:
        return None
    ordered=sorted(items);position=(len(ordered)-1)*q;low=int(position);high=math.ceil(position)
    return ordered[low]+(ordered[high]-ordered[low])*(position-low)


def counter_delta(items):
    if len(items)<2 or any(b<a for a,b in zip(items,items[1:])):
        return None
    return items[-1]-items[0]


def session(memory,rpcs3,operations,title,sequence=None):
    identifiers={(row.get('pid'),row.get('memoryProfile',{}).get('sessionSequence')) for row in memory
        if row.get('memoryProfile',{}).get('sampledSessionActive') is True}
    if sequence is not None:
        identifiers={item for item in identifiers if item[1]==sequence}
    if len(identifiers)!=1:
        raise ValueError('Select exactly one process/session with --baseline-session or --candidate-session')
    pid,selected=identifiers.pop()
    rows=[row for row in memory if row.get('pid')==pid and
        row.get('memoryProfile',{}).get('sessionSequence')==selected and
        (row.get('memoryProfile',{}).get('sampledSessionActive') is True or
         row.get('event')=='rpcs3_memory_session_end')]
    active=[row for row in rows if row.get('memoryProfile',{}).get('sampledSessionActive') is True]
    profile=active[0].get('experiment',{})
    if any(row.get('experiment')!=profile for row in active):
        raise ValueError('Mixed research profiles/source commits in one session')
    begin,end=rows[0]['timestamp'],rows[-1]['timestamp']
    performance=[row for row in rpcs3 if row.get('pid')==pid and begin<=row.get('timestamp',0)<=end]
    fps=[];thermal=[];matching=[]
    for row in performance:
        fields=dict(re.findall(r'(\w+)=([^\s]+)',row.get('message','')))
        if row.get('stage')!='performance_sample' or fields.get('title')!=title:
            continue
        matching.append(row)
        try:
            value=float(fields['fps'])
            valid=int(fields['valid'],0)&1
        except (KeyError,ValueError):
            continue
        if valid and math.isfinite(value) and value>=0:
            fps.append(value)
        if 'thermal' in fields:
            thermal.append(int(fields['thermal']))
    issues=[]
    if not profile.get('configured') or not profile.get('valid') or not profile.get('sourceCommit'):
        issues.append('explicit_profile_and_source_commit_missing')
    if rows[0].get('event')!='rpcs3_memory_session_start':issues.append('session_start_missing_or_rotated')
    if rows[-1].get('event')!='rpcs3_memory_session_end':issues.append('session_end_missing_cause_unknown')
    if not fps:issues.append('valid_same_title_fps_samples_missing')
    if any(row.get('diagnosticErrno',0) for row in rows):issues.append('diagnostic_write_failure')
    if profile.get('mode')=='baseline':
        for row in active:
            if any(row.get(key,0) for key in ('liveBytes','donationPreparedBytes')) or row.get('guestRelay',{}).get('liveBackingBytes',0):
                raise ValueError('Baseline has live NeoSwap allocations')
            if row.get('shaderStorage',{}).get('active'):raise ValueError('Baseline storage is active')
    source=[row.get('shaderStorage',{}).get('sourceArchive',{}) for row in rows]
    cache=[row.get('shaderStorage',{}).get('cache',{}) for row in rows]
    def delta(items,key):return counter_delta([item[key] for item in items if number(item.get(key))])
    faults=[row.get('processMemoryEvents',{}) for row in rows if row.get('processMemoryEvents',{}).get('valid')]
    batches=[row['batch'] for row in operations if row.get('pid')==pid and
        begin<=row.get('timestamp',0)<=end+2 and 'batch' in row]
    gaps=max([batch.get('droppedEventsCumulative',0) for batch in batches],default=0)
    if gaps:issues.append('operation_journal_reports_dropped_events')
    if profile.get('storage') and not batches:issues.append('operation_journal_not_supplied_or_no_operations')
    counts=Counter(event.get('operation','unknown') for batch in batches for event in batch.get('events',[]))
    footprint=values(active,'processFootprintBytes');resident=values(active,'processResidentBytes')
    available=values(active,'processAvailableBytes')
    if not footprint or not resident or not available:issues.append('memory_measurements_missing')
    boots={}
    for row in rpcs3:
        if row.get('pid')==pid and row.get('stage') in ('game_boot_begin','game_boot_end') and begin-2<=row.get('timestamp',0)<=end:
            boots[row['stage']]=row['timestamp']
    boot_seconds=boots.get('game_boot_end',0)-boots.get('game_boot_begin',0) if len(boots)==2 else None
    if boot_seconds is None:issues.append('boot_milestones_missing')
    return {
        'mode':profile.get('mode'),'sourceCommit':profile.get('sourceCommit'),'pid':pid,'session':selected,
        'physicalMemoryBytes':active[0].get('physicalMemoryBytes'),'osVersion':active[0].get('osVersion'),
        'title':title,'durationSeconds':end-begin,'samples':len(active),'completeSession':rows[-1].get('event')=='rpcs3_memory_session_end',
        'processFootprintPeakBytes':max(footprint) if footprint else None,
        'processResidentPeakBytes':max(resident) if resident else None,
        'processAvailableMinimumBytes':min(available) if available else None,
        'footprintChangeBytes':footprint[-1]-footprint[0] if len(footprint)>1 else None,
        'iosMemoryWarnings':delta(rows,'iosMemoryWarningCount'),
        'pressureSamples':sum(bool(row.get('memoryProfile',{}).get('pressureMask',0)&6) for row in active),
        'kernelFaults':delta(faults,'faults'),'kernelPageins':delta(faults,'pageins'),
        'sourceRestores':delta(source,'sourceReads'),'sourceDiskReadBytes':delta(source,'diskReadBytes'),
        'sourceDiskWriteBytes':delta(source,'diskWriteBytes'),'shaderDiskReadBytes':delta(cache,'bytesRead'),
        'shaderDiskWriteBytes':delta(cache,'bytesWritten'),
        'sourceRestorationQueueWaitUs':delta(source,'demandUtilityQueueWaitUsCumulative'),
        'sourceRestorationWorkUs':delta(source,'demandReadUsCumulative'),
        'sampledFpsMean':statistics.mean(fps) if fps else None,'sampledFpsP05':percentile(fps,0.05),
        'sampledFpsMinimum':min(fps) if fps else None,'fpsSamples':len(fps),'zeroFpsSamples':fps.count(0),
        'worstThermalState':max(thermal) if thermal else None,'coreBootSeconds':boot_seconds,
        'frameTimeP95Ms':None,'stutterCount':None,'jetsamCause':None,
        'operationCounts':dict(counts),'operationDropsCumulative':gaps,'issues':issues,
    }


def compare(baseline,candidate):
    if baseline['mode']!='baseline' or candidate['mode'] not in ('relay','integrated'):
        raise ValueError('Expected baseline vs relay/integrated profiles')
    for key in ('physicalMemoryBytes','osVersion','sourceCommit','title'):
        if not baseline[key] or baseline[key]!=candidate[key]:
            raise ValueError(f'Incompatible comparison: {key}')
    return {'schema':1,'baseline':baseline,'candidate':candidate,
        'candidateMinusBaseline':{key:candidate[key]-baseline[key] for key in (
            'processFootprintPeakBytes','processResidentPeakBytes','processAvailableMinimumBytes',
            'sampledFpsMean','coreBootSeconds') if number(baseline[key]) and number(candidate[key])},
        'deviceValidationPassed':False,'automaticPromotionAllowed':False,
        'limitations':['FPS sampled at 1 Hz; per-frame frametime and stutters unavailable from Core ABI30',
            'Kernel pageins/faults are not NeoSwap restorations','Missing session end does not identify jetsam/OOM',
            'Same game settings, device identity, save point and thermal conditions require test protocol confirmation']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for side in ('baseline','candidate'):
        parser.add_argument('--'+side,nargs='+',type=Path,required=True)
        parser.add_argument('--'+side+'-rpcs3',nargs='+',type=Path,required=True)
        parser.add_argument('--'+side+'-operations',nargs='+',type=Path,default=[])
        parser.add_argument('--'+side+'-session',type=int)
    parser.add_argument('--title',required=True);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();sessions=[]
    for side in ('baseline','candidate'):
        sessions.append(session(read_rows(getattr(args,side)),read_rows(getattr(args,side+'_rpcs3')),
            read_rows(getattr(args,side+'_operations')),args.title,getattr(args,side+'_session')))
    report=compare(*sessions);args.output.write_text(json.dumps(report,indent=2)+'\n')
    print('Comparison recorded; device validation and promotion remain pending')


if __name__=='__main__':main()
