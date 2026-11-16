/**
 * 数据源订阅记录持久化 —— 对应上游 LibreTV 的「数据源订阅」。
 *
 * 上游由服务端定时同步；App 没有常驻进程，所以这里只负责「记住订了什么、
 * 上次什么时候同步过、失败了几次」，真正的到期判断与拉取在 SubscriptionSync 里。
 */

import { Store } from './Store';
import { SubscriptionRecord } from '../model/Types';
import { EventBus, Events } from '../common/EventBus';
import { Utils } from '../common/Utils';

/** 连续失败多少次自动暂停（与上游一致） */
const PAUSE_AFTER_FAILURES: number = 3;

export class SubscriptionStore {
  private static readonly KEY = 'data_subscriptions';

  private static inst: SubscriptionStore | null = null;
  private list: SubscriptionRecord[] = [];
  private loaded = false;

  static shared(): SubscriptionStore {
    if (!SubscriptionStore.inst) {
      SubscriptionStore.inst = new SubscriptionStore();
    }
    return SubscriptionStore.inst;
  }

  private load(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const json = Store.shared().getJson(SubscriptionStore.KEY);
    if (json === '') {
      return;
    }
    try {
      const arr = JSON.parse(json) as object[];
      if (!Array.isArray(arr)) {
        return;
      }
      for (const raw of arr) {
        if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
          continue;
        }
        const rec = raw as Record<string, object>;
        const url = SubscriptionStore.str(rec['url']);
        if (url === '') {
          continue;
        }
        this.list.push({
          id: SubscriptionStore.str(rec['id']) !== '' ? SubscriptionStore.str(rec['id']) : Utils.stableId(url),
          url: url,
          name: SubscriptionStore.str(rec['name']),
          refreshDays: SubscriptionStore.num(rec['refreshDays'], 0),
          lastSync: SubscriptionStore.num(rec['lastSync'], 0),
          failStreak: SubscriptionStore.num(rec['failStreak'], 0),
          paused: SubscriptionStore.bool(rec['paused'], false),
          vodCount: SubscriptionStore.num(rec['vodCount'], 0),
          liveCount: SubscriptionStore.num(rec['liveCount'], 0),
          lastError: SubscriptionStore.str(rec['lastError'])
        });
      }
    } catch (e) {
      // 数据损坏当作没有订阅
    }
  }

  private save(): void {
    Store.shared().putJson(SubscriptionStore.KEY, JSON.stringify(this.list));
    EventBus.emit(Events.SUBSCRIPTIONS_CHANGED);
  }

  all(): SubscriptionRecord[] {
    this.load();
    return this.list.slice();
  }

  get(id: string): SubscriptionRecord | null {
    this.load();
    for (const r of this.list) {
      if (r.id === id) {
        return r;
      }
    }
    return null;
  }

  /**
   * 建档或更新。已存在时只更新地址与名称，不重置同步状态 ——
   * 用户重新粘一次同样的订阅地址，不该把「上次同步时间」和「暂停标记」清掉。
   */
  upsert(url: string, name: string): SubscriptionRecord {
    this.load();
    const id = Utils.stableId(url);
    for (const r of this.list) {
      if (r.id === id) {
        if (name !== '') {
          r.name = name;
        }
        this.save();
        return r;
      }
    }
    const rec: SubscriptionRecord = {
      id: id,
      url: url,
      name: name !== '' ? name : Utils.hostnameOf(url),
      // 默认关闭（纯手动），与上游面板默认值一致
      refreshDays: 0,
      lastSync: 0,
      failStreak: 0,
      paused: false,
      vodCount: 0,
      liveCount: 0,
      lastError: ''
    };
    this.list.push(rec);
    this.save();
    return rec;
  }

  /** 删除订阅记录（只删记录，已导入的源由调用方决定是否一并清理） */
  remove(id: string): void {
    this.load();
    const next: SubscriptionRecord[] = [];
    for (const r of this.list) {
      if (r.id !== id) {
        next.push(r);
      }
    }
    this.list = next;
    this.save();
  }

  setRefreshDays(id: string, days: number): void {
    this.load();
    for (const r of this.list) {
      if (r.id === id) {
        r.refreshDays = days < 0 ? 0 : days;
        // 改周期视为用户主动介入，解除暂停并清零失败计数（与上游一致）
        r.paused = false;
        r.failStreak = 0;
        this.save();
        return;
      }
    }
  }

  markSuccess(id: string, vodCount: number, liveCount: number): void {
    this.load();
    for (const r of this.list) {
      if (r.id === id) {
        r.lastSync = Date.now();
        r.failStreak = 0;
        r.paused = false;
        r.lastError = '';
        r.vodCount = vodCount;
        r.liveCount = liveCount;
        this.save();
        return;
      }
    }
  }

  markFailure(id: string, error: string): void {
    this.load();
    for (const r of this.list) {
      if (r.id === id) {
        r.failStreak += 1;
        r.lastError = error;
        if (r.failStreak >= PAUSE_AFTER_FAILURES) {
          r.paused = true;
        }
        this.save();
        return;
      }
    }
  }

  /** 到期且未暂停的订阅（refreshDays = 0 视为纯手动，永不到期） */
  due(now: number): SubscriptionRecord[] {
    this.load();
    const out: SubscriptionRecord[] = [];
    for (const r of this.list) {
      if (r.paused || r.refreshDays <= 0) {
        continue;
      }
      const interval = r.refreshDays * 24 * 3600 * 1000;
      if (r.lastSync === 0 || now - r.lastSync >= interval) {
        out.push(r);
      }
    }
    return out;
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }

  private static bool(v: object, def: boolean): boolean {
    return typeof v === 'boolean' ? (v as boolean) : def;
  }

  private static num(v: object, def: number): number {
    return typeof v === 'number' ? (v as number) : def;
  }
}
