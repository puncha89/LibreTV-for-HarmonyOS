/**
 * 聚合搜索服务：并行请求所有可用源 → 过滤 → 跨源同名合并
 * 另提供换源测速（与 LibreTV 换源逻辑对齐）
 */

import { CmsClient } from './CmsClient';
import { SourceManager } from '../data/SourceManager';
import { Settings, VodSource, SearchItem, MergedVideo, SpeedTestItem, CmsSearchPage } from './Types';
import { HttpClient } from '../net/HttpClient';
import { Utils } from '../common/Utils';

interface AggregateResult {
  merged: MergedVideo[];
  failedCount: number;
}

interface SourceSearchResult {
  ok: boolean;
  source: VodSource;
  items: SearchItem[];
}

export class SearchService {
  /**
   * 单个源的总死线（含全部分页）。
   * 上游 SEARCH_SOURCE_TIMEOUT_MS 默认 10s，移动网络略慢，这里给 12s。
   * 到点后已经发出的分页请求不强行中断（HTTP 层自己有 8s 超时），
   * 但不再补发后续页，避免「一个半死的源拖住整次搜索」。
   */
  private static readonly SOURCE_DEADLINE_MS: number = 12000;

  /**
   * 同时进行的源数量。
   * 上游跑在服务器上，可以几百个请求一起发；手机不行 ——
   * 100 个源 × 5 页 = 500 个并发会把移动网络的连接池打爆，
   * 表现为「搜索转很久然后一堆源报超时」，比只搜一页还差。
   * 分波跑既能压住峰值，又不会让常见规模（十几个源）变慢。
   */
  private static readonly SOURCE_CONCURRENCY: number = 8;

  /** 聚合搜索（多页） */
  static async aggregate(wd: string, settings: Settings): Promise<AggregateResult> {
    const sm = SourceManager.shared();
    const sources = sm.searchableVodSources(settings.adultFilter);
    const maxPages: number = SearchService.clampPages(settings.searchMaxPages);
    const results: SearchItem[] = [];
    let failed = 0;

    let index = 0;
    while (index < sources.length) {
      const wave: VodSource[] = sources.slice(index, index + SearchService.SOURCE_CONCURRENCY);
      index += SearchService.SOURCE_CONCURRENCY;
      const jobs: Promise<SourceSearchResult>[] = [];
      for (const s of wave) {
        jobs.push(SearchService.searchSource(s, wd, maxPages));
      }
      const settled = await Promise.all(jobs);
      for (const r of settled) {
        if (r.ok) {
          sm.recordSuccess(r.source.key);
          for (const item of r.items) {
            results.push(item);
          }
        } else {
          sm.recordFailure(r.source.key);
          failed++;
        }
      }
    }

    // 过滤：成人分类 + 相关性
    const filtered: SearchItem[] = [];
    for (const item of results) {
      if (settings.adultFilter && CmsClient.isAdultContent(item.typeName)) {
        continue;
      }
      if (!CmsClient.isRelevant(item.name, wd)) {
        continue;
      }
      filtered.push(item);
    }
    // 跨源同名合并
    const groups: MergedVideo[] = [];
    const index2 = new Map<string, MergedVideo>();
    for (const item of filtered) {
      const year = item.year !== undefined ? item.year : '';
      const key = Utils.normalizeTitle(item.name) + '|' + year;
      let g = index2.get(key);
      if (g === undefined) {
        g = {
          name: item.name,
          year: item.year,
          pic: item.pic,
          typeName: item.typeName,
          remarks: item.remarks,
          area: item.area,
          items: []
        };
        index2.set(key, g);
        groups.push(g);
      }
      g.items.push(item);
    }
    return { merged: groups, failedCount: failed };
  }

  private static clampPages(v: number): number {
    if (v === undefined || Number.isNaN(v) || v < 1) {
      return 1;
    }
    return v > 50 ? 50 : Math.floor(v);
  }

  /**
   * 抓一个源的全部页。
   * 先抓第一页（顺便拿 pagecount），再并行抓其余页；
   * 单页失败只丢该页 —— 不能因为第 4 页 500 就把前 3 页的结果也扔掉。
   */
  private static async searchSource(s: VodSource, wd: string, maxPages: number): Promise<SourceSearchResult> {
    const deadline: number = Date.now() + SearchService.SOURCE_DEADLINE_MS;
    let first: CmsSearchPage;
    try {
      first = await CmsClient.searchPage(s, wd, 1);
    } catch (e) {
      return { ok: false, source: s, items: [] as SearchItem[] };
    }
    const items: SearchItem[] = first.items.slice();
    let pages: number = maxPages;
    if (first.totalPage > 0 && first.totalPage < pages) {
      pages = first.totalPage;
    }
    if (pages > 1 && Date.now() < deadline) {
      const jobs: Promise<SearchItem[]>[] = [];
      for (let p = 2; p <= pages; p++) {
        jobs.push(CmsClient.searchPage(s, wd, p)
          .then((r: CmsSearchPage): SearchItem[] => r.items)
          .catch((): SearchItem[] => [] as SearchItem[]));
      }
      const more = await Promise.all(jobs);
      for (const arr of more) {
        for (const it of arr) {
          items.push(it);
        }
      }
    }
    return { ok: true, source: s, items: items };
  }

  /**
   * 换源测速：在各源搜索同名影片，取首个分片地址拉取播放列表计时。
   * 返回按延迟升序的可用源列表。
   */
  static async speedTest(name: string, excludeKey: string, settings: Settings): Promise<SpeedTestItem[]> {
    const sm = SourceManager.shared();
    const all = sm.searchableVodSources(settings.adultFilter);
    const sources: VodSource[] = [];
    for (const s of all) {
      if (s.key !== excludeKey) {
        sources.push(s);
      }
    }
    if (sources.length > 8) {
      sources.splice(8);
    }
    const wrapped: Promise<SpeedTestItem>[] = [];
    for (const s of sources) {
      wrapped.push(SearchService.probeSource(s, name));
    }
    const settled = await Promise.all(wrapped);
    const ok: SpeedTestItem[] = [];
    const bad: SpeedTestItem[] = [];
    for (const r of settled) {
      if (r.ok) {
        ok.push(r);
      } else {
        bad.push(r);
      }
    }
    ok.sort((a, b) => a.latencyMs - b.latencyMs);
    for (const b of bad) {
      ok.push(b);
    }
    return ok;
  }

  private static async probeSource(s: VodSource, name: string): Promise<SpeedTestItem> {
    const miss: SpeedTestItem = {
      sourceKey: s.key,
      sourceName: s.name,
      episodeUrl: '',
      latencyMs: 0,
      ok: false,
      episodeCount: 0
    };
    try {
      const items = await CmsClient.search(s, name);
      let best: SearchItem | null = null;
      for (const it of items) {
        if (CmsClient.isRelevant(it.name, name)) {
          best = it;
          break;
        }
      }
      if (best === null) {
        return miss;
      }
      let url = '';
      let count = 0;
      if (best.playUrl !== undefined && best.playUrl !== '') {
        const eps = CmsClient.extractEpisodes(best.playUrl);
        count = eps.length;
        if (eps.length > 0) {
          url = eps[0].url;
        }
      }
      if (url === '') {
        const detail = await CmsClient.detail(s, best.vodId);
        count = detail.episodes.length;
        if (detail.episodes.length > 0) {
          url = detail.episodes[0].url;
        }
      }
      if (url === '') {
        return miss;
      }
      const t0 = Date.now();
      const res = await HttpClient.getText(url, HttpClient.cmsHeaders(), 6000);
      const latency = Date.now() - t0;
      const playable = res.ok && (res.text.indexOf('#EXTINF') >= 0 || res.text.indexOf('#EXT-X-STREAM-INF') >= 0);
      return {
        sourceKey: s.key,
        sourceName: s.name,
        vodId: best.vodId,
        episodeUrl: url,
        latencyMs: latency,
        ok: playable,
        episodeCount: count
      };
    } catch (e) {
      return miss;
    }
  }
}
