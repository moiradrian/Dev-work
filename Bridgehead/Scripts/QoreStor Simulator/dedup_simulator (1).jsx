import React, { useState, useMemo } from 'react';
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer
} from 'recharts';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

// Core simulation logic
function simulateRetention(
  days,
  sourceSizeTiB,
  changeRate,
  initialCompressionPct,
  compressionPct,
  dailyRetention,
  weeklyRetention,
  monthlyRetention,
  yearlyRetention,
  cloudDelay
) {
  const backupLog = [];
  const storedLocal = [];
  const storedCloud = [];
  const dedupePre = [];
  const dedupePost = [];
  const dailyUncomp = [];
  const dailyComp = [];
  const requiredKeys = [];
  const dictSizes = [];
  const tierMeta = [];

  const dailyCut = dailyRetention;
  const weeklyCut = dailyCut + weeklyRetention * 7;
  const monthlyCut = weeklyCut + monthlyRetention * 30;
  const yearlyCut = monthlyCut + yearlyRetention * 365;

  let lastLogical = sourceSizeTiB;
  let lastCompArchive = 0;

  // 1️⃣ build log of deltas
  for (let day = 0; day < days; day++) {
    const effectiveCompression = day === 0
      ? initialCompressionPct
      : compressionPct;

    const delta = day === 0
      ? sourceSizeTiB
      : lastLogical * changeRate;

    const logical = day === 0 ? sourceSizeTiB : lastLogical + delta;

    const compDelta = delta * (1 - effectiveCompression);
    const fullComp = logical * (1 - effectiveCompression);

    lastCompArchive = day === 0
      ? fullComp
      : lastCompArchive + compDelta;

    backupLog.push({
      day,
      delta,
      logical,
      compDelta,
      fullComp,
      tiers: [
        'daily',
        ...(day % 7 === 0 ? ['weekly'] : []),
        ...(day % 30 === 0 ? ['monthly'] : []),
        ...(day % 365 === 0 ? ['yearly'] : [])
      ]
    });

    dailyUncomp.push(delta);
    dailyComp.push(compDelta);
    lastLogical = logical;
  }

  // 2️⃣ apply retention & cloud split
  for (let today = 0; today < days; today++) {
    let sumUn = 0, sumComp = 0;
    let locUn = 0, locComp = 0;
    let cluUn = 0, cluComp = 0;
    let kept = 0;

    backupLog.forEach(snap => {
      const age = today - snap.day;
      if (age < 0) return;
      const keep =
        age < dailyCut ||
        (age >= dailyCut && age < weeklyCut && snap.tiers.includes('weekly')) ||
        (age >= weeklyCut && age < monthlyCut && snap.tiers.includes('monthly')) ||
        (age >= monthlyCut && age < yearlyCut && snap.tiers.includes('yearly'));
      if (!keep) return;
      kept++;
      sumUn += snap.delta;
      const c = snap.day === 0 ? snap.fullComp : snap.compDelta;
      sumComp += c;

      // local always holds base+changes until cloudDelay, but base remains after
      if (snap.day === 0 || age < cloudDelay) {
        locUn += snap.delta;
        locComp += c;
      }
      // cloud copy: base only once, changes after delay
      if (snap.day === 0 && age >= cloudDelay) {
        cluUn += snap.delta;
        cluComp += snap.fullComp;
      } else if (snap.day !== 0 && age >= cloudDelay) {
        cluUn += snap.delta;
        cluComp += c;
      }
    });

    // efficiencies
    const rawHeldPre = sourceSizeTiB * kept;
    const preEff = rawHeldPre > 0 ? ((rawHeldPre - sumUn) / rawHeldPre) * 100 : 0;
    const rawHeldPost = sumUn;
    const postEff = rawHeldPost > 0 ? ((rawHeldPost - sumComp) / rawHeldPost) * 100 : 0;

    storedLocal.push(locComp);
    storedCloud.push(cluComp);
    dedupePre.push(Math.max(0, preEff));
    dedupePost.push(Math.max(0, postEff));

    // keys & dict per day
    const footprint = locComp + cluComp;
    const numKeys = Math.floor(footprint * 1024 ** 3 / 8);
    requiredKeys.push(numKeys);
    // assume keyLookupTable defined globally
    const tier = keyLookupTable.find(k => numKeys >= k.min && numKeys <= k.max) || {};
    tierMeta.push(tier);
    dictSizes.push(tier.Size || 'N/A');
  }

  const stats = {
    totalLogical: sourceSizeTiB * days,
    heldRaw: sourceSizeTiB * kept,
    totalComp: storedLocal.at(-1) + storedCloud.at(-1),
    totalCloud: storedCloud.at(-1),
    dedupePre: dedupePre.at(-1),
    dedupePost: dedupePost.at(-1)
  };

  return {
    storedLocal,
    storedCloud,
    dedupePre,
    dedupePost,
    dailyUncomp,
    dailyComp,
    requiredKeys,
    dictSizes,
    stats
  };
}

export default function DedupSimulator() {
  const [sourceSize, setSourceSize] = useState(10);
  const [changeRate, setChangeRate] = useState(0.02);
  const [dailyRet, setDailyRet] = useState(12);
  const [weeklyRet, setWeeklyRet] = useState(4);
  const [monthlyRet, setMonthlyRet] = useState(11);
  const [yearlyRet, setYearlyRet] = useState(7);
  const [months, setMonths] = useState(3);
  const [initialComp, setInitialComp] = useState(0.1);
  const [compPct, setCompPct] = useState(0.1);
  const [cloudDelay, setCloudDelay] = useState(5);

  const days = months * 30;
  const labels = Array.from({ length: days }, (_, i) => `Day ${i+1}`);

  const data = useMemo(() => {
    const {
      storedLocal,
      storedCloud,
      dedupePre,
      dedupePost,
      dailyUncomp,
      dailyComp,
      requiredKeys,
      dictSizes,
      stats
    } = simulateRetention(
      days,
      sourceSize,
      changeRate,
      initialComp,
      compPct,
      dailyRet,
      weeklyRet,
      monthlyRet,
      yearlyRet,
      cloudDelay
    );
    return { labels, storedLocal, storedCloud, dedupePre, dedupePost, dailyUncomp, dailyComp, requiredKeys, dictSizes, stats };
  }, [days, sourceSize, changeRate, initialComp, compPct, dailyRet, weeklyRet, monthlyRet, yearlyRet, cloudDelay]);

  const exportCsv = () => {
    const rows = [
      ['Param','Value'],
      ['Source Size', sourceSize],
      ['Change Rate', changeRate],
      ['Initial Compression', initialComp],
      ['Regular Compression', compPct],
      ['Daily Ret', dailyRet],
      ['Weekly Ret', weeklyRet],
      ['Monthly Ret', monthlyRet],
      ['Yearly Ret', yearlyRet],
      ['Cloud Delay', cloudDelay],
      [],
      ['Day','LocalTiB','CloudTiB','PreEff','PostEff']
    ];
    data.labels.forEach((d,i) => rows.push([
      d,
      data.storedLocal[i].toFixed(2),
      data.storedCloud[i].toFixed(2),
      data.dedupePre[i].toFixed(2),
      data.dedupePost[i].toFixed(2)
    ]));
    const csv = rows.map(r => r.join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = 'dedupe.csv'; a.click(); URL.revokeObjectURL(url);
  };

  return (
    <div className="p-6 space-y-6">
      <div className="grid grid-cols-3 gap-4">
        <div><Label>Source Size (TiB)</Label><Input type="number" value={sourceSize} onChange={e=>setSourceSize(+e.target.value)} /></div>
        <div><Label>Change Rate (%)</Label><Input type="number" step="0.01" value={changeRate*100} onChange={e=>setChangeRate(+e.target.value/100)} /></div>
        <div><Label>Months</Label><Input type="number" value={months} onChange={e=>setMonths(+e.target.value)} /></div>
        <div><Label>Initial Compression (%)</Label><Input type="number" step="0.01" value={initialComp*100} onChange={e=>setInitialComp(+e.target.value/100)} /></div>
        <div><Label>Regular Compression (%)</Label><Input type="number" step="0.01" value={compPct*100} onChange={e=>setCompPct(+e.target.value/100)} /></div>
        <div><Label>Cloud Delay (days)</Label><Input type="number" value={cloudDelay} onChange={e=>setCloudDelay(+e.target.value)} /></div>
      </div>
      <div className="space-y-4">
        <ResponsiveContainer width="100%" height={200}>
          <LineChart data={data.labels.map((d,i)=>({day:d, local:data.storedLocal[i], cloud:data.storedCloud[i]}))}>
            <XAxis dataKey="day" hide />
            <YAxis />
            <CartesianGrid strokeDasharray="3 3" />
            <Tooltip />
            <Legend />
            <Line type="monotone" dataKey="local" stroke="#4ade80" dot={false} />
            <Line type="monotone" dataKey="cloud" stroke="#60a5fa" dot={false} />
          </LineChart>
        </ResponsiveContainer>
        <ResponsiveContainer width="100%" height={200}>
          <LineChart data={data.labels.map((d,i)=>({day:d, pre:data.dedupePre[i], post:data.dedupePost[i]}))}>
            <XAxis dataKey="day" hide />
            <YAxis domain={[0,100]} />
            <CartesianGrid strokeDasharray="3 3" />
            <Tooltip />
            <Legend />
            <Line type="monotone" dataKey="pre" stroke="#f59e0b" dot={false} />
            <Line type="monotone" dataKey="post" stroke="#8b5cf6" dot={false} />
          </LineChart>
        </ResponsiveContainer>
      </div>
      <Button onClick={exportCsv}>Export CSV</Button>
    </div>
  );
}
