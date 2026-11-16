/**
 * 全局类型定义（与 LibreTV Web 版数据结构对齐）
 */

export interface VodSource {
  key: string;
  name: string;
  /** Apple CMS V10 接口地址，如 https://example.com/api.php/provide/vod */
  url: string;
  detail?: string;
  enabled: boolean;
  isAdult: boolean;
  /** 健康度：连续失败次数 */
  failStreak: number;
  /** 停用截止时间戳（0 表示未停用） */
  disabledUntil: number;
  /** 来自哪个订阅（订阅 id）；手动添加的源没有这个字段 */
  subId?: string;
}

export interface LiveSource {
  key: string;
  name: string;
  /** M3U/M3U8 播放列表地址 */
  url: string;
  /** XMLTV 节目单地址（可选） */
  epg?: string;
  enabled: boolean;
  failStreak: number;
  disabledUntil: number;
  /** 来自哪个订阅（订阅 id）；手动添加的源没有这个字段 */
  subId?: string;
}

export interface SearchItem {
  sourceKey: string;
  sourceName: string;
  vodId: string;
  name: string;
  pic?: string;
  typeName?: string;
  year?: string;
  area?: string;
  remarks?: string;
  actor?: string;
  director?: string;
  content?: string;
  playFrom?: string;
  playUrl?: string;
}

/** 单页搜索结果：items 是这一页的条目，totalPage 是源站声明的总页数（0 = 未声明） */
export interface CmsSearchPage {
  items: SearchItem[];
  totalPage: number;
}

/**
 * 订阅记录：对应上游「数据源订阅」条目。
 *
 * 上游跑在服务端，可以真的起定时任务；App 没有常驻进程，
 * 所以语义退化成「启动 App / 进入源管理页时检查是否到期」，
 * 到期才在后台静默同步。周期值（refreshDays）与面板选项保持一致：
 * 0 = 关闭（纯手动），1 / 3 / 7 / 14 / 30 天。
 */
export interface SubscriptionRecord {
  /** 以订阅地址生成的稳定 id */
  id: string;
  url: string;
  name: string;
  /** 刷新周期（天），0 = 关闭（纯手动） */
  refreshDays: number;
  /** 上次同步成功的时间戳，0 = 从未同步 */
  lastSync: number;
  /** 连续失败次数，达到 3 次自动暂停 */
  failStreak: number;
  /** 是否已暂停（连续失败 3 次后置位） */
  paused: boolean;
  /** 上次同步导入的点播源 / 直播源数量，仅用于展示 */
  vodCount: number;
  liveCount: number;
  /** 上次失败原因，成功时清空 */
  lastError: string;
}

/** 一次订阅同步的结果 */
export interface SubscriptionSyncResult {
  ok: boolean;
  vodAdded: number;
  liveAdded: number;
  skipped: number;
  error: string;
}

/** 批量探活结果汇总 */
export interface ProbeSummary {
  ok: number;
  bad: number;
}

/** 跨源同名聚合后的卡片 */
export interface MergedVideo {
  name: string;
  year?: string;
  pic?: string;
  typeName?: string;
  remarks?: string;
  area?: string;
  items: SearchItem[];
}

export interface Episode {
  index: number;
  name: string;
  url: string;
}

/** 播放线路：一部影片可有多个播放来源（vod_play_from / vod_play_url 按 $$$ 对齐） */
export interface PlayLine {
  name: string;
  episodes: Episode[];
}

export interface DetailInfo {
  title: string;
  cover?: string;
  desc?: string;
  typeName?: string;
  year?: string;
  area?: string;
  director?: string;
  actor?: string;
  remarks?: string;
  /** 源站评分（CMS 的 vod_score），可能是 '0.0' / ''，由详情页判断是否可用 */
  score?: string;
  sourceKey: string;
  sourceName: string;
  sourceUrl: string;
  /** 多条播放线路；只有 1 条时不返回 */
  lines?: PlayLine[];
}

export interface VideoDetail {
  episodes: Episode[];
  info: DetailInfo;
}

export interface PlayRecord {
  sourceKey: string;
  vodId: string;
  name: string;
  pic?: string;
  sourceName: string;
  /** 当前集下标 */
  episode: number;
  episodeName?: string;
  /** 播放地址（换源后可能变化） */
  playUrl?: string;
  /** 播放线路下标（多线路影片记忆所选线路） */
  lineIndex?: number;
  positionMs: number;
  durationMs: number;
  updatedAt: number;
}

export interface FavoriteItem {
  sourceKey: string;
  vodId: string;
  name: string;
  pic?: string;
  sourceName: string;
  createdAt: number;
}

/** 直播频道收藏项：与点播 FavoriteItem 并列存储，一起进「我的收藏」 */
export interface LiveFavoriteItem {
  url: string;
  name: string;
  logo?: string;
  sourceKey: string;
  sourceName: string;
  createdAt: number;
}

export interface LiveChannel {
  id: string;
  name: string;
  url: string;
  logo?: string;
  group?: string;
  tvgId?: string;
}

export interface LiveChannelItem extends LiveChannel {
  sourceKey: string;
  sourceName: string;
}

export interface EpgProgramme {
  channelId: string;
  title: string;
  start: number;
  stop: number;
}

export interface DownloadTaskRecord {
  id: string;
  sourceKey: string;
  vodId: string;
  name: string;
  pic?: string;
  sourceName: string;
  episode: number;
  episodeName: string;
  /** pending / downloading / completed / failed */
  status: string;
  done: number;
  total: number;
  dir: string;
  updatedAt: number;
  error?: string;
  /** 原始分集播放地址；存下来才能在应用被系统回收后继续下载 */
  episodeUrl?: string;
}

/**
 * 订阅导出结构。
 * 键名必须与 SubscriptionParser.parseSourceList 读取的一致（sources / liveSources），
 * 否则导出的文件粘回「导入订阅」会被解析成空列表。
 */
export interface ExportVodEntry {
  name: string;
  api: string;
  isAdult?: boolean;
}

export interface ExportLiveEntry {
  name: string;
  url: string;
  epg?: string;
}

export interface SourceExportPayload {
  name: string;
  updateTime: string;
  sources: ExportVodEntry[];
  liveSources: ExportLiveEntry[];
}

export interface SpeedTestItem {
  sourceKey: string;
  sourceName: string;
  /** 换源后该源中同名视频的 id（用于重新拉取详情） */
  vodId?: string;
  episodeUrl: string;
  latencyMs: number;
  ok: boolean;
  episodeCount: number;
}

export interface RecommendItem {
  id: string;
  title: string;
  cover: string;
  rating?: string;
  isTv: boolean;
}

export interface Settings {
  /** off / loose / strict */
  adFilter: string;
  autoNext: boolean;
  adultFilter: boolean;
  /** system / light / dark */
  themeMode: string;
  /** douban_movie / douban_tv / douban_rank / bangumi */
  recommendSource: string;
  defaultSpeed: number;
  playHistoryEnabled: boolean;
  /** 自动发现源：启动时拉取内置聚合订阅并验活入库（默认关闭） */
  autoDiscover: boolean;
  /**
   * 每个搜索源最多抓取的页数（1-50，默认 5）。
   * 与上游 SEARCH_MAX_PAGES 对齐：第一页读源站 pagecount，
   * 实际页数 = min(源站总页数, 本值)；页间并行，单页失败只丢该页。
   */
  searchMaxPages: number;
}

export const DEFAULT_SETTINGS: Settings = {
  adFilter: 'loose',
  autoNext: true,
  adultFilter: true,
  themeMode: 'system',
  recommendSource: 'douban_movie',
  defaultSpeed: 1.0,
  playHistoryEnabled: true,
  autoDiscover: false,
  searchMaxPages: 5
};
