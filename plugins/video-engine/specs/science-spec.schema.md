# science-spec —— 教育科普视频规范模板（强制先行）

理化生地数学的教育视频**必须**先产出本规范，`render.py` 对缺失/不达标
spec 硬拒（`spec_missing` / `spec_invalid`，exit 2）。规范是 RSI 环②
「科学对照核查」的对照物——facts 清单里每一条都会被逐条核对。

## 字段契约

```jsonc
{
  "kind": "science",              // 固定
  "subject": "斜面上的摩擦力",     // 主题（一句话）
  "domain": "physics",            // physics|chemistry|biology|math|geography
  "laws": [                       // ≥1：本片涉及的定律/定理/方程式（原文级别）
    "滑动摩擦力 f = μN，N 为法向压力",
    "牛顿第二定律 F = ma"
  ],
  "assumptions": [                // ≥1：理想化假设显式声明（不许静默简化）
    "滑块视为质点，忽略空气阻力",
    "斜面与滑块均为刚体",
    "μ 在全程视为常数"
  ],
  "params": {                     // 全部数字量（带量纲写 note；值必须是纯数字）
    "g": 9.8,
    "theta_deg": 30,
    "mu": 0.12,
    "scale_px_per_m": 200
  },
  "formulas": [                   // 本片动画使用的公式（timeline 的 expr 只能
                                  //  引用这里声明的名字与 params 键）
    { "name": "theta", "expr": "radians(theta_deg)" },
    { "name": "a",     "expr": "g * (sin(theta) - mu * cos(theta))" },
    { "name": "x_px",  "expr": "0.5 * a * scale_px_per_m" }
  ],
  "facts": [                      // ≥1：事实核查清单——RSI 环②逐条对照
    "a 恒定（μ、θ 不随时间变），位移应为时间的二次函数",
    "μ=0.12、θ=30° 时 tan(θ)≈0.577 > μ，滑块确实下滑",
    "数值读数单位为 m/s 与 m，与 scale_px_per_m 换算一致"
  ],
  "storyboard": [                 // 分镜：每个场景一帧的意图（对照 scenes 用）
    { "note": "场景斜面 + 滑块 + 受力箭头", "duration": 6 },
    { "note": "位移/速度实时读数", "duration": 4 }
  ]
}
```

## 硬规则（违反 = 管线拒绝或环②打回）

1. **params 全数字**——单位/量纲写进字段名或 note（`theta_deg`、
   `scale_px_per_m`），值里不许带字符串单位。
2. **timeline 的 expr 只能引用**：`t`（场景内时间）/`T`（全局时间）/
   `params` 键 / `formulas` 名字 / 内建 `pi`、`e` / math 白名单函数
   （sin cos tan sqrt abs min max floor ceil log exp pow radians degrees
   atan2 asin acos）。出现任何未声明标识符 → `undeclared_symbol` 拒绝。
3. **不许在 timeline 里现写物理公式**绕开 spec——公式必须在 spec.formulas
   声明（环②对照 timeline expr 与 formulas 一致性）。
4. **assumptions 必须诚实**：理想化条件（无空气阻力、质点、刚体）必须
   显式列出；片子旁白/标注与假设冲突即环② fail。
5. facts 是给评审 agent 的核查清单，每条一句话可判真伪。
