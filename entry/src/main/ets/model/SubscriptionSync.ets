/**
 * 数据源订阅同步 —— 对应上游「订阅 / ⟳ 手动同步 / 自动刷新」。
 *
 * 与上游的语义差异（平台约束，必须说清而不是假装一致）：
 *   上游跑在服务端，能真的起定时任务，到期就自己同步；
 *   App 没有常驻后台进程，只能在「启动 App」和「进入源管理页」这两个时机
 *   检查是否到期。所以「3 天一刷」的含义是「至少每 3 天，只要我打开过 App」，
 *   而不是「到点必定刷新」。这与用户预期基本吻合，但绝不能写成定时任务。
 *
 * 同步策略与上游一致：整体替换 —— 该订阅名下旧的源先摘掉，再按远端列表重建。
 * 手动添加的源（没有 subId）不受影响。
 */

import { SubscriptionRecord, SubscriptionSyncResult, LiveSource } from './Types';
import { SubscriptionParser, FlexibleParseResult } from './SubscriptionParser';
import { SourceManager } from '../data/SourceManager';
import { SubscriptionStore } from '../data/SubscriptionStore';
import { HttpClient } from '../net/HttpClient';

export class SubscriptionSync {
  /** 一次最多同步几个订阅（与上游一致：单次最多 5 个、并发 2 个） */
  private static readonly MAX_PER_RUN: number = 5;
  private static readonly CONCURRENCY: number = 2;

  /** 同步单个订阅：拉取 → 解析 → 整体替换该订阅名下的源 */
  static async syncOne(rec: SubscriptionRecord): Promise<SubscriptionSyncResult> {
    const res = await HttpClient.getTextAny(rec.url, { 'User-Agent': HttpClient.UA }, 12000);
    if (!res.ok || res.text === '') {
      return { ok: false, vodAdded: 0, liveAdded: 0, skipped: 0, error: '订阅地址拉取失败' };
    }
    let fr: FlexibleParseResult;
    try {
      fr = SubscriptionParser.parseFlexible(res.text);
    } catch (e) {
      const err = e as Error;
      return { ok: false, vodAdded: 0, liveAdded: 0, skipped: 0, error: err.message !== undefined ? err.message : '订阅内容无法解析' };
    }
    const sm = SourceManager.shared();
    // 先摘旧的再重建：远端删掉的源要跟着消失，否则「订阅」就成了只增不减
    sm.removeBySubscription(rec.id);

    if (fr.kind === 'json' && fr.sub !== undefined) {
      const vod = sm.addVodSources(fr.sub.vod, rec.id);
      const live = sm.addLiveSources(fr.sub.live, rec.id);
      return { ok: true, vodAdded: vod, liveAdded: live, skipped: fr.sub.skipped, error: '' };
    }
    // 播放列表型订阅（地址直链到 M3U / TXT）：登记成一个直播源
    if (fr.channels.length === 0) {
      return { ok: false, vodAdded: 0, liveAdded: 0, skipped: 0, error: '未解析到任何频道' };
    }
    const liveSrc: LiveSource = {
      key: '',
      name: rec.name !== '' ? rec.name : rec.url,
      url: rec.url,
      epg: undefined,
      enabled: true,
      failStreak: 0,
      disabledUntil: 0
    };
    const added = sm.addLiveSources([liveSrc], rec.id);
    return { ok: true, vodAdded: 0, liveAdded: added, skipped: 0, error: '' };
  }

  /** 手动同步（⟳）：不论是否到期都同步一次 */
  static async syncNow(id: string): Promise<string> {
    const store = SubscriptionStore.shared();
    const rec = store.get(id);
    if (rec === null) {
      return '订阅不存在';
    }
    const r = await SubscriptionSync.syncOne(rec);
    if (r.ok) {
      store.markSuccess(rec.id, r.vodAdded, r.liveAdded);
      let msg = '「' + rec.name + '」已同步：' + r.vodAdded + ' 个点播源';
      if (r.liveAdded > 0) {
        msg = msg + '、' + r.liveAdded + ' 个直播源';
      }
      if (r.skipped > 0) {
        msg = msg + '（跳过 ' + r.skipped + ' 个不可用条目）';
      }
      return msg;
    }
    store.markFailure(rec.id, r.error);
    return '「' + rec.name + '」同步失败：' + r.error;
  }

  /**
   * 检查到期并静默同步（启动 App / 进源管理页时调用）。
   * 返回给用户看的一句话摘要；没有到期订阅时返回空串（不要弹「无事发生」的提示）。
   */
  static async syncDue(): Promise<string> {
    const store = SubscriptionStore.shared();
    const due = store.due(Date.now());
    if (due.length === 0) {
      return '';
    }
    const batch = due.slice(0, SubscriptionSync.MAX_PER_RUN);
    let vod = 0;
    let live = 0;
    let failed = 0;
    let i = 0;
    while (i < batch.length) {
      const wave = batch.slice(i, i + SubscriptionSync.CONCURRENCY);
      i += SubscriptionSync.CONCURRENCY;
      const jobs: Promise<SubscriptionSyncResult>[] = [];
      for (const rec of wave) {
        jobs.push(SubscriptionSync.syncOne(rec));
      }
      const results = await Promise.all(jobs);
      for (let k = 0; k < results.length; k++) {
        const r = results[k];
        if (r.ok) {
          store.markSuccess(wave[k].id, r.vodAdded, r.liveAdded);
          vod += r.vodAdded;
          live += r.liveAdded;
        } else {
          store.markFailure(wave[k].id, r.error);
          failed++;
        }
      }
    }
    let msg = '订阅已自动刷新：新增 ' + vod + ' 个点播源';
    if (live > 0) {
      msg = msg + '、' + live + ' 个直播源';
    }
    if (failed > 0) {
      msg = msg + '，' + failed + ' 个订阅同步失败';
    }
    return msg;
  }
}
