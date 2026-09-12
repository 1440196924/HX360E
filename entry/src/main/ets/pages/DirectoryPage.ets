import { fileIo as fs } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'HX360E';

class DirEntry {
  name: string = '';
  isDir: boolean = false;
  size: number = 0;
}

/**
 * 模拟器目录：应用沙箱内的文件浏览（其他 App 无权访问本应用沙箱，
 * 所以这里用应用内浏览代替「用文件管理器打开」）。
 */
@Component
export struct DirectoryPage {
  @State rootPath: string = '';
  @State currentPath: string = '';
  @State entries: DirEntry[] = [];
  @State statusText: string = '';

  aboutToAppear(): void {
    let dir: string = '';
    try {
      const ctx = getContext(this) as common.Context;
      dir = ctx.filesDir;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'filesDir failed: %{public}s', JSON.stringify(e));
    }
    this.rootPath = dir;
    this.currentPath = dir;
    this.reload();
  }

  reload(): void {
    const list: DirEntry[] = [];
    if (this.currentPath === '') {
      this.entries = list;
      return;
    }
    try {
      const names: string[] = fs.listFileSync(this.currentPath);
      for (const name of names) {
        const full: string = `${this.currentPath}/${name}`;
        const entry = new DirEntry();
        entry.name = name;
        try {
          const st = fs.statSync(full);
          entry.isDir = st.isDirectory();
          entry.size = st.size;
        } catch (e) {
          entry.isDir = false;
          entry.size = 0;
        }
        list.push(entry);
      }
    } catch (e) {
      this.statusText = '读取目录失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'list dir failed: %{public}s', JSON.stringify(e));
    }
    list.sort((a: DirEntry, b: DirEntry) => {
      if (a.isDir !== b.isDir) {
        return a.isDir ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    this.entries = list;
  }

  enter(name: string): void {
    this.currentPath = `${this.currentPath}/${name}`;
    this.reload();
  }

  goUp(): void {
    if (this.currentPath === this.rootPath || this.currentPath.length === 0) {
      return;
    }
    const slash: number = this.currentPath.lastIndexOf('/');
    if (slash > 0) {
      this.currentPath = this.currentPath.substring(0, slash);
      this.reload();
    }
  }

  async copyPath(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,
        this.currentPath);
      await pasteboard.getSystemPasteboard().setData(data);
      this.statusText = `已复制路径：${this.currentPath}`;
    } catch (e) {
      this.statusText = '复制失败（见 hilog）';
      hilog.error(DOMAIN, TAG, 'copy path failed: %{public}s', JSON.stringify(e));
    }
  }

  private formatSize(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }
    if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(0)} KB`;
    }
    return `${bytes} B`;
  }

  @Builder
  entryRow(item: DirEntry) {
    Row({ space: 10 }) {
      Text(item.isDir ? '📁' : '📄').fontSize(16)
      Column({ space: 2 }) {
        Text(item.name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.isDir ? '目录' : this.formatSize(item.size))
          .fontSize(11)
          .fontColor($r('app.color.text_hint'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (item.isDir) {
        Text('›').fontSize(18).fontColor($r('app.color.text_hint'))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      if (item.isDir) {
        this.enter(item.name);
      }
    })
  }

  build() {
    NavDestination() {
      Column() {

      Text(this.currentPath)
        .fontSize(11)
        .fontColor($r('app.color.text_hint'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 6 })

      Row({ space: 8 }) {
        Button('上一级').fontSize(12).height(30)
          .enabled(this.currentPath !== this.rootPath)
          .onClick(() => this.goUp())
        Button('复制路径').fontSize(12).height(30)
          .onClick(() => this.copyPath())
        Button('游戏目录').fontSize(12).height(30)
          .onClick(() => {
            this.currentPath = `${this.rootPath}/games`;
            this.reload();
          })
        Button('日志目录').fontSize(12).height(30)
          .onClick(() => {
            this.currentPath = `${this.rootPath}/logs`;
            this.reload();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      List() {
        ForEach(this.entries, (item: DirEntry) => {
          ListItem() {
            this.entryRow(item)
          }
        }, (item: DirEntry) => item.name)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Text(this.statusText)
        .fontSize(11)
        .fontColor($r('app.color.accent'))
        .maxLines(2)
        .padding({ left: 16, right: 16, bottom: 12 })
    }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
    }
    .title('模拟器目录')
  }
}
