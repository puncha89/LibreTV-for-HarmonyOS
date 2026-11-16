/**
 * 影视榜单（hot-list）—— 与上游 LibreTV 的「影视榜单」推荐源对齐。
 *
 * 数据来自 60s API（https://github.com/vikiboss/60s，免 key）：
 *   豆瓣五个周榜：/v2/douban/weekly/{movie|tv_chinese|tv_global|show_chinese|show_global}
 *   百度热播剧：  /v2/baidu/teleplay
 * 返回结构统一是 { code, data: [...] }。
 *
 * 与上游的差异：上游服务端做了 1 小时内存缓存与封面代理；
 * 客户端没有共享缓存，这里只做「一次全量拉取 + 按需重取」，
 * 封面直接用上游给的 img*.doubanio.com 地址（缺失时回退镜像域名）。
 */

import { RecommendItem } from './Types';
import { HttpClient } from '../net/HttpClient';

export class HotListClient {
  /** 社区实例优先，失败回退官方公共实例（与上游一致） */
  private static readonly BASE: string = 'https://60s.crystelf.top';
  private static readonly FALLBACK: string = 'https://60s.viki.moe';
  private static readonly UA: string = 'LibreTV-HarmonyOS';

  /** 榜单标识 → 60s API 路径 */
  private static pathOf(id: string): string {
    if (id === 'douban_tv_chinese') {
      return '/v2/douban/weekly/tv_chinese';
    }
    if (id === 'douban_tv_global') {
      return '/v2/douban/weekly/tv_global';
    }
    if (id === 'douban_show_chinese') {
      return '/v2/douban/weekly/show_chinese';
    }
    if (id === 'douban_show_global') {
      return '/v2/douban/weekly/show_global';
    }
    if (id === 'baidu_teleplay') {
      return '/v2/baidu/teleplay';
    }
    return '/v2/douban/weekly/movie';
  }

  static async fetch(id: string): Promise<RecommendItem[]> {
    const bases: string[] = HotListClient.BASE === HotListClient.FALLBACK
      ? [HotListClient.BASE]
      : [HotListClient.BASE, HotListClient.FALLBACK];
    let lastError: string = '';
    for (const base of bases) {
      try {
        const items = await HotListClient.fetchOnce(base, id);
        if (items.length > 0) {
          return items;
        }
        lastError = '榜单数据为空';
      } catch (e) {
        const err = e as Error;
        lastError = err.message !== undefined ? err.message : '榜单请求失败';
      }
    }
    throw new Error(lastError !== '' ? lastError : '榜单请求失败');
  }

  private static async fetchOnce(base: string, id: string): Promise<RecommendItem[]> {
    const url: string = base + HotListClient.pathOf(id);
    const res = await HttpClient.getText(url, {
      'User-Agent': HotListClient.UA,
      'Accept': 'application/json'
    }, 10000);
    if (!res.ok || res.text === '') {
      throw new Error('60s API 响应异常 (' + res.status + ')');
    }
    const root = JSON.parse(res.text) as Record<string, object>;
    const data = root['data'];
    if (!Array.isArray(data)) {
      throw new Error('榜单数据异常');
    }
    // 除了电影周榜，其余都按「剧集」处理（点击卡片走标题搜索，这个标记只影响角标）
    const isTv: boolean = id !== 'douban_movie_weekly';
    const out: RecommendItem[] = [];
    const arr = data as object[];
    for (let i = 0; i < arr.length; i++) {
      const entry = arr[i] as Record<string, object>;
      const title = HotListClient.str(entry['title']);
      if (title === '') {
        continue;
      }
      // cover 是 img*.doubanio.com 原生地址，cover_proxy 是限流较严的镜像，仅兜底
      let cover = HotListClient.str(entry['cover']);
      if (cover === '') {
        cover = HotListClient.str(entry['cover_proxy']);
      }
      if (cover === '') {
        // 没有海报的条目直接丢：首页卡片是图墙，留个灰块比不显示更难看
        continue;
      }
      let rid = '';
      const rawId = entry['id'];
      if (typeof rawId === 'number') {
        rid = (rawId as number).toString();
      } else if (typeof rawId === 'string') {
        rid = rawId as string;
      }
      if (rid === '') {
        // 百度榜没有稳定 id，用榜单内序号保证 key 唯一
        rid = 'hot_' + i;
      }
      const item: RecommendItem = {
        id: rid,
        title: title,
        cover: cover,
        isTv: isTv
      };
      const rate = HotListClient.numOf(entry['rating']);
      if (rate > 0) {
        item.rating = rate.toFixed(1);
      }
      out.push(item);
    }
    return out;
  }

  private static str(v: object): string {
    return typeof v === 'string' ? (v as string) : '';
  }

  private static numOf(v: object): number {
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n = Number.parseFloat(v as string);
      return Number.isNaN(n) ? 0 : n;
    }
    return 0;
  }
}
