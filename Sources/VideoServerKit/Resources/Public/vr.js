'use strict';

// VR 映像の描画。
//
// three.js のような外部ライブラリは使わない。LAN 内で完結させたいので
// CDN に依存させたくないし、やりたいことは「画面いっぱいの矩形 1 枚に対して
// 画素ごとの視線方向を求め、投影方式に応じて動画から色を拾う」だけで、
// ジオメトリもシーングラフも要らないため。
//
// 投影方式と立体方式の組み合わせはすべて同じシェーダで扱う。
// 分岐は uniform で渡す。

const Vr = (() => {
  const VERT = `
    attribute vec2 aPos;
    varying vec2 vNdc;
    void main() {
      vNdc = aPos;
      gl_Position = vec4(aPos, 0.0, 1.0);
    }
  `;

  // uProjection: 0=360°正距円筒, 1=180°正距円筒, 2=180°魚眼
  // uStereo:     0=モノラル, 1=左右分割, 2=上下分割
  //
  // テクスチャは UNPACK_FLIP_Y_WEBGL を立てないので、画像の上端が v=0。
  // 正距円筒では v=0 が天頂にあたるので、そのまま acos(y)/PI でよい。
  const FRAG = `
    precision highp float;
    varying vec2 vNdc;
    uniform sampler2D uTex;
    uniform mat3 uRot;
    uniform float uAspect;
    uniform float uTanHalfFov;
    uniform int uProjection;
    uniform int uStereo;

    const float PI = 3.141592653589793;

    void main() {
      vec3 dir = normalize(vec3(vNdc.x * uAspect * uTanHalfFov,
                                vNdc.y * uTanHalfFov,
                                -1.0));
      dir = uRot * dir;

      vec2 uv;
      bool ok = true;

      if (uProjection == 2) {
        // 魚眼 180°: 正面から 90° までを半径 1 の円に写す。
        float theta = acos(clamp(-dir.z, -1.0, 1.0));
        float r = theta / (PI * 0.5);
        if (r > 1.0) ok = false;
        float phi = atan(dir.y, dir.x);
        uv = vec2(0.5 + 0.5 * r * cos(phi), 0.5 - 0.5 * r * sin(phi));
      } else {
        float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
        if (uProjection == 1) {
          // 180°: 背面には映像が無いので黒で塗る。
          if (dir.z > 0.0) ok = false;
          uv = vec2(atan(dir.x, -dir.z) / PI + 0.5, v);
        } else {
          uv = vec2(atan(dir.x, -dir.z) / (2.0 * PI) + 0.5, v);
        }
      }

      if (!ok) {
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
      }

      // 立体映像は左目 (左半分 / 上半分) だけを使う。
      if (uStereo == 1) uv.x *= 0.5;
      else if (uStereo == 2) uv.y *= 0.5;

      gl_FragColor = texture2D(uTex, uv);
    }
  `;

  let gl = null, canvas = null, video = null;
  let program = null, texture = null, buffer = null;
  const u = {};
  let raf = 0;

  let projection = 'off';
  let stereo = 'mono';
  // 縦方向の視野角。ピンチで変えられ、正面に戻す操作と VR を閉じたときに既定値へ戻る。
  const DEFAULT_FOV = 75;
  const MIN_FOV = 30;
  const MAX_FOV = 110;
  let fovDeg = DEFAULT_FOV;

  // 手で動かしたぶん。世界座標での回転をクォータニオンで持つ。
  // センサー使用時は向きの補正として、センサーの姿勢の手前に掛ける。
  let offset = [0, 0, 0, 1];
  let sensorOn = false;
  let sensorQuat = null;
  let needsAlign = false;
  let screenAngle = 0;

  let onError = null;
  let textureFailed = false;

  const PROJECTIONS = { equirect360: 0, equirect180: 1, fisheye180: 2 };
  const STEREOS = { mono: 0, sbs: 1, tb: 2 };

  // ===== 行列とクォータニオン =====

  function multiplyQuat(a, b) {
    const [ax, ay, az, aw] = a, [bx, by, bz, bw] = b;
    return [
      ax * bw + aw * bx + ay * bz - az * by,
      ay * bw + aw * by + az * bx - ax * bz,
      az * bw + aw * bz + ax * by - ay * bx,
      aw * bw - ax * bx - ay * by - az * bz,
    ];
  }

  // 端末の姿勢 (alpha/beta/gamma) からカメラの姿勢を作る。
  //
  // W3C の定義そのまま (beta→X, gamma→Y, alpha→Z を ZXY 順) だと
  // 「端末がどう傾いているか」は得られるが、「画面の向こうを見る
  // カメラがどちらを向いているか」にはならない。
  // 角度の割り当てと合成順序を次のようにする必要がある:
  //   X に beta、Y に alpha、Z に -gamma を入れ、YXZ 順で合成する。
  //
  // そのうえで端末を立てて持った状態が正面になるよう X 軸まわりに
  // -90° 回し、最後に画面の回転ぶんを打ち消す。
  function quatFromOrientation(alpha, beta, gamma, angle) {
    const d = Math.PI / 180;
    const x = beta * d, y = alpha * d, z = -gamma * d;

    const c1 = Math.cos(x / 2), s1 = Math.sin(x / 2);
    const c2 = Math.cos(y / 2), s2 = Math.sin(y / 2);
    const c3 = Math.cos(z / 2), s3 = Math.sin(z / 2);

    // YXZ 順の合成。
    let q = [
      s1 * c2 * c3 + c1 * s2 * s3,
      c1 * s2 * c3 - s1 * c2 * s3,
      c1 * c2 * s3 - s1 * s2 * c3,
      c1 * c2 * c3 + s1 * s2 * s3,
    ];
    q = multiplyQuat(q, [-Math.SQRT1_2, 0, 0, Math.SQRT1_2]);
    const o = -angle * d;
    return multiplyQuat(q, [0, 0, Math.sin(o / 2), Math.cos(o / 2)]);
  }

  function mat3FromQuat(q) {
    const [x, y, z, w] = q;
    const x2 = x + x, y2 = y + y, z2 = z + z;
    const xx = x * x2, xy = x * y2, xz = x * z2;
    const yy = y * y2, yz = y * z2, zz = z * z2;
    const wx = w * x2, wy = w * y2, wz = w * z2;
    // 列優先で並べる (WebGL の uniformMatrix3fv がそれを期待する)。
    return [
      1 - (yy + zz), xy + wz, xz - wy,
      xy - wz, 1 - (xx + zz), yz + wx,
      xz + wy, yz - wx, 1 - (xx + yy),
    ];
  }

  function multiplyMat3(a, b) {
    const out = new Array(9);
    for (let c = 0; c < 3; c++) {
      for (let r = 0; r < 3; r++) {
        out[c * 3 + r] = a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2];
      }
    }
    return out;
  }

  // 軸 (単位ベクトル) まわりに angle 回すクォータニオン (右手系)。
  function quatAxisAngle(axis, angle) {
    const s = Math.sin(angle / 2);
    return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(angle / 2)];
  }

  // 掛け算を重ねると誤差で長さがずれ、像が歪むので 1 に戻す。
  function normalizeQuat(q) {
    const len = Math.hypot(q[0], q[1], q[2], q[3]) || 1;
    return [q[0] / len, q[1] / len, q[2] / len, q[3] / len];
  }

  // ===== WebGL =====

  function compile(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      throw new Error(gl.getShaderInfoLog(s) || 'シェーダのコンパイルに失敗');
    }
    return s;
  }

  function setup() {
    gl = canvas.getContext('webgl', { alpha: false, antialias: false })
      || canvas.getContext('experimental-webgl', { alpha: false, antialias: false });
    if (!gl) throw new Error('WebGL を使えません');

    program = gl.createProgram();
    gl.attachShader(program, compile(gl.VERTEX_SHADER, VERT));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(program) || 'シェーダのリンクに失敗');
    }
    gl.useProgram(program);

    buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    // 画面全体を覆う 2 枚の三角形。
    gl.bufferData(gl.ARRAY_BUFFER,
      new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(program, 'aPos');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    for (const name of ['uTex', 'uRot', 'uAspect', 'uTanHalfFov', 'uProjection', 'uStereo']) {
      u[name] = gl.getUniformLocation(program, name);
    }

    texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    // 動画は 2 の冪乗とは限らないので、繰り返しもミップマップも使えない。
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.uniform1i(u.uTex, 0);
  }

  function resize() {
    // 画素密度をそのまま使うと負荷が高いので 2 倍までに抑える。
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.round(canvas.clientWidth * ratio);
    const h = Math.round(canvas.clientHeight * ratio);
    if (w > 0 && h > 0 && (canvas.width !== w || canvas.height !== h)) {
      canvas.width = w;
      canvas.height = h;
    }
    gl.viewport(0, 0, canvas.width, canvas.height);
  }

  // 視線 f に垂直な水平の右向き軸。真上・真下を見ているときは
  // 水平面が決まらないので、画面の右向き r を水平面に落として使う。
  function horizontalRight(f, r) {
    let h = [-f[2], 0, f[0]];
    let len = Math.hypot(h[0], h[2]);
    if (len < 1e-3) {
      h = [r[0], 0, r[2]];
      len = Math.hypot(h[0], h[2]) || 1;
    }
    return [h[0] / len, 0, h[2] / len];
  }

  function currentRotation() {
    const o = mat3FromQuat(offset);
    if (sensorOn && sensorQuat) {
      // センサーの姿勢に、手で回したぶんを世界座標で掛けて正面をずらす。
      // 手の補正を手前に掛けるので、そのあと端末を傾けても、
      // 視線はずらした先で素直に上下左右へ動く。
      return multiplyMat3(o, mat3FromQuat(sensorQuat));
    }
    return o;
  }

  function frame() {
    raf = requestAnimationFrame(frame);
    if (!gl || projection === 'off') return;

    resize();

    if (!textureFailed && video.readyState >= 2 && video.videoWidth > 0) {
      gl.bindTexture(gl.TEXTURE_2D, texture);
      try {
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, video);
      } catch (e) {
        // 環境によっては動画をテクスチャにできない
        // (HLS をそのまま再生している場合など)。
        textureFailed = true;
        if (onError) onError('この動画は VR 表示に使えませんでした');
      }
    }

    gl.clearColor(0, 0, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.uniformMatrix3fv(u.uRot, false, new Float32Array(currentRotation()));
    gl.uniform1f(u.uAspect, canvas.width / Math.max(1, canvas.height));
    gl.uniform1f(u.uTanHalfFov, Math.tan((fovDeg * Math.PI / 180) / 2));
    gl.uniform1i(u.uProjection, PROJECTIONS[projection] ?? 0);
    gl.uniform1i(u.uStereo, STEREOS[stereo] ?? 0);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  // ===== センサー =====

  // センサーの alpha (方位) の基準は端末任せで、動画の正面とは関係がない。
  // そのままだと、平らに置いた端末を立てたときに横を向いてしまう。
  // そこで入れた直後 (と正面に戻す操作のとき) の端末の向きを正面とみなす。
  //
  // 方位は視線の水平成分から求める。平らに置いて真下を見ているときは
  // 視線に水平成分が無いので、画面の上端が指す向きを使う
  // (horizontalRight が画面の右向きに切り替えるので、それと直交する向き)。
  // こうすると、平らな状態から持ち上げたときに正面を向く。
  function alignToDevice() {
    const s = mat3FromQuat(sensorQuat);
    const h = horizontalRight([-s[6], -s[7], -s[8]], [s[0], s[1], s[2]]);
    // 水平な正面 (h[2], 0, -h[0]) の方位角。その分だけ鉛直軸まわりに打ち消す。
    offset = quatAxisAngle([0, 1, 0], Math.atan2(h[2], h[0]));
  }

  function onDeviceOrientation(e) {
    if (e.alpha == null) return;
    sensorQuat = quatFromOrientation(e.alpha, e.beta || 0, e.gamma || 0, screenAngle);
    if (needsAlign) {
      needsAlign = false;
      alignToDevice();
    }
  }

  function readScreenAngle() {
    screenAngle = (screen.orientation && screen.orientation.angle) || window.orientation || 0;
  }

  return {
    /// 初期化。canvas と動画要素を結び付ける。
    init(videoEl, canvasEl, errorHandler) {
      video = videoEl;
      canvas = canvasEl;
      onError = errorHandler || null;
      readScreenAngle();
      window.addEventListener('orientationchange', readScreenAngle);
      window.addEventListener('resize', readScreenAngle);
    },

    /// 投影方式と立体方式を設定する。'off' で描画を止める。
    setMode(proj, stereoMode) {
      projection = proj || 'off';
      stereo = stereoMode || 'mono';
      textureFailed = false;

      if (projection === 'off') {
        this.stop();
        return true;
      }
      if (!gl) {
        try {
          setup();
        } catch (e) {
          if (onError) onError(e.message);
          projection = 'off';
          return false;
        }
      }
      canvas.hidden = false;
      if (!raf) raf = requestAnimationFrame(frame);
      return true;
    },

    /// 描画を止め、canvas を隠す。
    stop() {
      if (raf) { cancelAnimationFrame(raf); raf = 0; }
      if (canvas) canvas.hidden = true;
      projection = 'off';
      this.setSensor(false);
      offset = [0, 0, 0, 1];
      fovDeg = DEFAULT_FOV;
    },

    get active() { return projection !== 'off'; },

    /// 画面上の移動量だけ視点を回す。
    ///
    /// 指を動かした向きに視界が動く (風景をつかんで引き寄せるのではなく、
    /// 顔を向ける感覚)。実機で試して自然だった方に合わせてある。
    drag(dx, dy) {
      const scale = (fovDeg * Math.PI / 180) / Math.max(1, canvas.clientHeight);
      // 画面の軸まわりに回す。左右は画面の上向き、上下は画面の右向きが軸。
      //
      // 世界の鉛直軸まわりに左右を回すと、真上・真下 (極) を見ているときに
      // その場で回るだけで極を越えられない。画面の軸を使えば、どこを
      // 見ていても像は指の動いた方へ動き、上下左右どちらでも極を越えられる。
      // 端末を傾けて持っていても、画面の縦横に沿って動く。
      //
      // 代わりに、斜めの操作を重ねると水平線が傾くことがある。
      // 正面に戻す操作で元に戻る。
      let m = currentRotation();
      offset = multiplyQuat(quatAxisAngle([m[3], m[4], m[5]], dx * scale), offset);
      m = currentRotation();
      offset = multiplyQuat(quatAxisAngle([m[0], m[1], m[2]], dy * scale), offset);
      offset = normalizeQuat(offset);
    },

    /// 指の間隔の変化率 (今 / 直前) だけ拡大・縮小する。
    /// 指を広げると視野角が狭まって拡大、縮めると広がって縮小になる。
    zoom(ratio) {
      if (!(ratio > 0)) return;
      fovDeg = Math.max(MIN_FOV, Math.min(MAX_FOV, fovDeg / ratio));
    },

    /// 指をひねった角度 (ラジアン、画面上で時計回りが正) だけ、
    /// 視線を軸に回す。像は指と同じ向きに回る。
    ///
    /// 斜めのスワイプを重ねて水平線が傾いたときに、ひねって直せる。
    twist(delta) {
      const m = currentRotation();
      // 視線の逆向き (画面の手前向き) を軸に正の向きへ回すと、
      // カメラが反時計回りに回り、像は時計回りに回る。
      offset = normalizeQuat(multiplyQuat(quatAxisAngle([m[6], m[7], m[8]], delta), offset));
    },

    /// 正面に戻す。センサー使用時は今の端末の向きを正面にする。
    /// 拡大・縮小も既定の視野角に戻す。
    recenter() {
      fovDeg = DEFAULT_FOV;
      if (sensorOn && sensorQuat) {
        alignToDevice();
      } else {
        offset = [0, 0, 0, 1];
      }
    },

    /// センサー追随の入切。iOS は利用者の操作を起点とした許可要求が要る。
    async setSensor(on) {
      if (!on) {
        sensorOn = false;
        sensorQuat = null;
        window.removeEventListener('deviceorientation', onDeviceOrientation);
        return false;
      }
      const DOE = window.DeviceOrientationEvent;
      if (!DOE) {
        if (onError) onError('この端末では姿勢センサーを使えません');
        return false;
      }
      if (typeof DOE.requestPermission === 'function') {
        try {
          const res = await DOE.requestPermission();
          if (res !== 'granted') {
            if (onError) onError('センサーの使用が許可されませんでした');
            return false;
          }
        } catch (e) {
          // HTTPS でない場合などはここに来る。
          if (onError) onError('センサーを使えません (HTTPS で開いてください)');
          return false;
        }
      }
      readScreenAngle();
      needsAlign = true;
      window.addEventListener('deviceorientation', onDeviceOrientation);
      sensorOn = true;
      return true;
    },

    get sensorEnabled() { return sensorOn; },
  };
})();
