# screenplay-spec —— 艺术类视频剧本规范模板（强制先行）

简笔画 / 沙雕动画 / 影视复刻 / 观赏性动画**必须**先产出本剧本规范，
`render.py` 硬拒缺失（`spec_missing`，exit 2）。规范是 RSI 环②③的
对照物：beats 逐拍核对节奏，style 锚定视觉一致性。

## 字段契约

```jsonc
{
  "kind": "screenplay",           // 固定
  "title": "跳跳的小人",
  "style": "sand-sketch 沙雕简笔：火柴人、粗线条、夸张挤压拉伸、
            高饱和点缀色",           // 风格锚（一段话，视觉评审对照物）
  "palette": ["#111111", "#FFB65C", "#4ECDC4"],   // 主色（≤5，越少越稳）
  "characters": [                 // 角色表（每个可动主体一条）
    { "id": "stick", "desc": "火柴人：圆头+单线躯干+线四肢",
      "parts": ["head", "body", "arm_l", "arm_r", "leg_l", "leg_r"] }
  ],
  "beats": [                      // 分镜拍点：≥1，at 为全局秒
    { "at": 0.0, "what": "小人入画，站定" },
    { "at": 0.8, "what": "蓄力下蹲（挤压）" },
    { "at": 1.2, "what": "起跳（拉伸+离地）" },
    { "at": 2.4, "what": "落地回弹，帽子弹飞" },
    { "at": 3.5, "what": "对白气泡：『再来一次！』" }
  ],
  "gags": ["挤压拉伸要夸张（scale 0.7↔1.3）", "落地必带 2 帧压扁"],
  "params": {},                   // 动画辅助常量（可选，全数字）
  "formulas": []                  // 若用到 expr（如弹跳高度），在此声明
}
```

## 硬规则

1. **beats 是节奏法律**：timeline scenes 的元素 delay/时长必须能映射回
   beats.at（环②核对每个 beat 有对应画面载体）。
2. **style 锚定**：环③视觉评审以 style+palette 为基准；成片出现
   palette 外的高饱和色即 fail。
3. **角色 parts 分解**：可动主体必须拆部件（animation-planner 的组件
   独立运动原则）——timeline 里每个部件是独立 element，不许整角色一张图。
4. **影视复刻声明**：style 里注明致敬来源与「简单复刻」的抽象程度
   （几何剪影/简笔），环③按该抽象度评审，不以原片画质苛求。
5. 用到数值动画（弹跳/摆动）时公式进 formulas，同 science 硬规则 2。
