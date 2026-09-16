const STICK_DEADZONE: number = 0.12;

/**
 * 手柄按键：自带按下反馈（背景变亮 + 描边加亮 + 轻微缩小）。
 * 每个按键自己持有按下状态，因此多点触控下可以同时按住多个键。
 */
@Component
export struct PadButton {
  @Prop label: string = '';
  @Prop btnWidth: number = 44;
  @Prop btnHeight: number = 44;
  @Prop round: boolean = true;
  @Prop fontSize: number = 18;
  fill: ResourceColor = '#59000000';
  pressedFill: ResourceColor = '#8C000000';
  textColor: ResourceColor = '#E6FFFFFF';
  onPress: (pressed: boolean) => void = (pressed: boolean) => {
  };
  @State pressed: boolean = false;

  build() {
    Button(this.label)
      .fontSize(this.fontSize)
      .fontColor(this.textColor)
      .backgroundColor(this.pressed ? this.pressedFill : this.fill)
      .border({
        width: this.pressed ? 3 : 2,
        color: this.pressed ? '#CCFFFFFF' : '#40FFFFFF',
      })
      .borderRadius(this.round ? this.btnWidth / 2 : 12)
      .width(this.btnWidth)
      .height(this.btnHeight)
      .padding(0)
      // 虚拟手柄按钮不参与焦点：手柄十字键默认会用来做焦点导航，
      // 会在这些按钮之间跳焦点（游戏页不需要任何焦点）。
      .focusable(false)
      .focusOnTouch(false)
      .scale({ x: this.pressed ? 0.92 : 1, y: this.pressed ? 0.92 : 1 })
      .onTouch((e: TouchEvent) => {
        if (e.type === TouchType.Down) {
          this.pressed = true;
          this.onPress(true);
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.pressed = false;
          this.onPress(false);
        }
      })
  }
}

/**
 * 虚拟摇杆：大圆底盘 + 可拖拽的摇杆帽。
 * 回调给出归一化坐标 (x, y)，范围 [-1, 1]；x 右为正，y 上为正（屏幕 y 向下已翻转）。
 */
@Component
export struct VirtualStick {
  @Prop diameter: number = 118;
  @Prop knobDiameter: number = 48;
  baseColor: ResourceColor = '#59000000';
  rimColor: ResourceColor = '#40FFFFFF';
  knobColor: ResourceColor = '#3DFFFFFF';
  onStick: (x: number, y: number) => void = (x: number, y: number) => {
  };
  @State knobDx: number = 0;
  @State knobDy: number = 0;
  @State active: boolean = false;
  // 本摇杆当前跟踪的手指 id（多点触控下只认按下时落在这里的那根）。
  private pointerId: number = -1;

  private maxOffset(): number {
    return (this.diameter - this.knobDiameter) / 2;
  }

  private findPointer(e: TouchEvent): TouchObject | undefined {
    for (let i = 0; i < e.touches.length; i++) {
      if (e.touches[i].id === this.pointerId) {
        return e.touches[i];
      }
    }
    return undefined;
  }

  private isChangedPointerMine(e: TouchEvent): boolean {
    for (let i = 0; i < e.changedTouches.length; i++) {
      if (e.changedTouches[i].id === this.pointerId) {
        return true;
      }
    }
    return false;
  }

  private updateFromTouch(px: number, py: number): void {
    const center: number = this.diameter / 2;
    let dx: number = px - center;
    let dy: number = py - center;
    const max: number = this.maxOffset();
    const len: number = Math.sqrt(dx * dx + dy * dy);
    if (len > max && len > 0) {
      dx = dx / len * max;
      dy = dy / len * max;
    }
    this.knobDx = dx;
    this.knobDy = dy;
    if (max <= 0) {
      return;
    }
    this.onStick(dx / max, -dy / max);
  }

  private release(): void {
    this.knobDx = 0;
    this.knobDy = 0;
    this.active = false;
    this.onStick(0, 0);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 底盘
      Column()
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.diameter / 2)
        .backgroundColor(this.baseColor)
        .border({ width: 2, color: this.rimColor })
      // 底盘上的四个小刻度点（呼应参考图）
      Column()
        .width(4)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.rimColor)
        .offset({ x: 0, y: -(this.diameter / 2 - 22) })
      Column()
        .width(4)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.rimColor)
        .offset({ x: this.diameter / 2 - 22, y: 0 })
      Column()
        .width(4)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.rimColor)
        .offset({ x: -(this.diameter / 2 - 22), y: 0 })
      Column()
        .width(4)
        .height(4)
        .borderRadius(2)
        .backgroundColor(this.rimColor)
        .offset({ x: 0, y: this.diameter / 2 - 22 })
      // 摇杆帽
      Column()
        .width(this.knobDiameter)
        .height(this.knobDiameter)
        .borderRadius(this.knobDiameter / 2)
        .backgroundColor(this.active ? '#59FFFFFF' : this.knobColor)
        .border({ width: 2, color: this.rimColor })
        .offset({ x: this.knobDx, y: this.knobDy })
    }
    .width(this.diameter)
    .height(this.diameter)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        // 已有手指在控制本摇杆时不抢占（多点触控可同时操作左右摇杆）。
        if (this.pointerId < 0 && e.changedTouches.length > 0) {
          const t: TouchObject = e.changedTouches[0];
          this.pointerId = t.id;
          this.active = true;
          this.updateFromTouch(t.x, t.y);
        }
      } else if (e.type === TouchType.Move) {
        const t: TouchObject | undefined = this.findPointer(e);
        if (t !== undefined) {
          this.updateFromTouch(t.x, t.y);
        }
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.isChangedPointerMine(e)) {
          this.pointerId = -1;
          this.release();
        }
      }
    })
  }
}

/**
 * 十字键：圆形底盘 + 十字，按触点相对中心的方向给出 4 向数字输入。
 */
@Component
export struct VirtualDpad {
  @Prop diameter: number = 118;
  baseColor: ResourceColor = '#59000000';
  rimColor: ResourceColor = '#40FFFFFF';
  crossColor: ResourceColor = '#33FFFFFF';
  activeColor: ResourceColor = '#73FFFFFF';
  onDir: (up: boolean, down: boolean, left: boolean, right: boolean) => void =
    (up: boolean, down: boolean, left: boolean, right: boolean) => {
    };
  @State pressedUp: boolean = false;
  @State pressedDown: boolean = false;
  @State pressedLeft: boolean = false;
  @State pressedRight: boolean = false;
  // 本十字键当前跟踪的手指 id。
  private pointerId: number = -1;

  private findPointer(e: TouchEvent): TouchObject | undefined {
    for (let i = 0; i < e.touches.length; i++) {
      if (e.touches[i].id === this.pointerId) {
        return e.touches[i];
      }
    }
    return undefined;
  }

  private isChangedPointerMine(e: TouchEvent): boolean {
    for (let i = 0; i < e.changedTouches.length; i++) {
      if (e.changedTouches[i].id === this.pointerId) {
        return true;
      }
    }
    return false;
  }

  private emit(): void {
    this.onDir(this.pressedUp, this.pressedDown, this.pressedLeft,
      this.pressedRight);
  }

  private updateFromTouch(px: number, py: number): void {
    const center: number = this.diameter / 2;
    const dx: number = px - center;
    const dy: number = py - center;
    const dead: number = this.diameter * STICK_DEADZONE;
    let up: boolean = false;
    let down: boolean = false;
    let left: boolean = false;
    let right: boolean = false;
    if (Math.sqrt(dx * dx + dy * dy) >= dead) {
      if (Math.abs(dx) > Math.abs(dy)) {
        left = dx < 0;
        right = dx > 0;
      } else {
        up = dy < 0;
        down = dy > 0;
      }
    }
    this.pressedUp = up;
    this.pressedDown = down;
    this.pressedLeft = left;
    this.pressedRight = right;
    this.emit();
  }

  private release(): void {
    this.pressedUp = false;
    this.pressedDown = false;
    this.pressedLeft = false;
    this.pressedRight = false;
    this.emit();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 底盘
      Column()
        .width(this.diameter)
        .height(this.diameter)
        .borderRadius(this.diameter / 2)
        .backgroundColor(this.baseColor)
        .border({ width: 2, color: this.rimColor })
      // 基础十字（竖条 + 横条）
      Column()
        .width(this.diameter * 0.40)
        .height(this.diameter * 0.92)
        .borderRadius(10)
        .backgroundColor(this.crossColor)
      Column()
        .width(this.diameter * 0.92)
        .height(this.diameter * 0.40)
        .borderRadius(10)
        .backgroundColor(this.crossColor)
      // 按下时只高亮对应那一段（不是整条都亮）
      if (this.pressedUp) {
        Column()
          .width(this.diameter * 0.40)
          .height(this.diameter * 0.46)
          .borderRadius(10)
          .backgroundColor(this.activeColor)
          .offset({ x: 0, y: -(this.diameter * 0.23) })
      }
      if (this.pressedDown) {
        Column()
          .width(this.diameter * 0.40)
          .height(this.diameter * 0.46)
          .borderRadius(10)
          .backgroundColor(this.activeColor)
          .offset({ x: 0, y: this.diameter * 0.23 })
      }
      if (this.pressedLeft) {
        Column()
          .width(this.diameter * 0.46)
          .height(this.diameter * 0.40)
          .borderRadius(10)
          .backgroundColor(this.activeColor)
          .offset({ x: -(this.diameter * 0.23), y: 0 })
      }
      if (this.pressedRight) {
        Column()
          .width(this.diameter * 0.46)
          .height(this.diameter * 0.40)
          .borderRadius(10)
          .backgroundColor(this.activeColor)
          .offset({ x: this.diameter * 0.23, y: 0 })
      }
    }
    .width(this.diameter)
    .height(this.diameter)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        if (this.pointerId < 0 && e.changedTouches.length > 0) {
          const t: TouchObject = e.changedTouches[0];
          this.pointerId = t.id;
          this.updateFromTouch(t.x, t.y);
        }
      } else if (e.type === TouchType.Move) {
        const t: TouchObject | undefined = this.findPointer(e);
        if (t !== undefined) {
          this.updateFromTouch(t.x, t.y);
        }
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.isChangedPointerMine(e)) {
          this.pointerId = -1;
          this.release();
        }
      }
    })
  }
}
