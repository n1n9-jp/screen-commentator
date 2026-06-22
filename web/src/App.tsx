import { FormEvent, useEffect, useMemo, useState } from 'react';
import { supabase } from './supabase';

const MAX_COMMENT_LENGTH = 80;
const OTP_RESEND_COOLDOWN_SECONDS = 60;

type SessionState = 'checking' | 'signed-out' | 'otp-sent' | 'signed-in';
type AuthMode = 'password' | 'otp';

function roomCodeFromPath(): string {
  const match = window.location.pathname.match(/\/r\/([A-Za-z0-9_-]+)/);
  return match?.[1]?.toUpperCase() ?? '';
}

function isAllowedMusabiEmail(email: string): boolean {
  const parts = email.trim().toLowerCase().split('@');
  if (parts.length !== 2 || !parts[0] || !parts[1]) return false;
  const domain = parts[1];
  return domain === 'musabi.ac.jp' || domain.endsWith('.musabi.ac.jp');
}

function normalizeComment(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function normalizeOtpToken(text: string): string {
  return text
    .trim()
    .replace(/[０-９]/g, (char) => String(char.charCodeAt(0) - 0xff10))
    .replace(/\s+/g, '');
}

function roomURL(roomCode: string): string {
  return `${window.location.origin}/r/${encodeURIComponent(roomCode)}`;
}

function authParamsFromURL(): URLSearchParams {
  return new URLSearchParams(`${window.location.search}&${window.location.hash.replace(/^#/, '')}`);
}

function isPasswordRecoveryURL(): boolean {
  return authParamsFromURL().get('type') === 'recovery';
}

export function App() {
  const roomCode = useMemo(roomCodeFromPath, []);
  const [sessionState, setSessionState] = useState<SessionState>('checking');
  const [isPasswordRecovery, setIsPasswordRecovery] = useState(isPasswordRecoveryURL);
  const [passwordRecoveryComplete, setPasswordRecoveryComplete] = useState(false);
  const [authMode, setAuthMode] = useState<AuthMode>('otp');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [newPasswordConfirmation, setNewPasswordConfirmation] = useState('');
  const [otp, setOtp] = useState('');
  const [comment, setComment] = useState('');
  const [message, setMessage] = useState('');
  const [isBusy, setIsBusy] = useState(false);
  const [otpCooldownRemaining, setOtpCooldownRemaining] = useState(0);

  useEffect(() => {
    let isMounted = true;
    const urlError = authErrorFromURL();
    const recoveryURL = isPasswordRecoveryURL();

    supabase.auth.getSession().then(({ data }) => {
      if (!isMounted) return;
      setSessionState(data.session ? 'signed-in' : 'signed-out');
      setIsPasswordRecovery(recoveryURL && !!data.session);
      if (urlError) {
        setMessage(urlError);
        window.history.replaceState({}, document.title, window.location.pathname);
      }
    });

    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY' || (isPasswordRecoveryURL() && !!session)) {
        setIsPasswordRecovery(true);
        setMessage('新しいパスワードを設定してください。');
      }
      setSessionState(session ? 'signed-in' : 'signed-out');
    });

    return () => {
      isMounted = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (otpCooldownRemaining <= 0) return;

    const timer = window.setTimeout(() => {
      setOtpCooldownRemaining((remaining) => Math.max(remaining - 1, 0));
    }, 1000);

    return () => window.clearTimeout(timer);
  }, [otpCooldownRemaining]);

  function authErrorFromURL(): string {
    const params = authParamsFromURL();
    const code = params.get('error_code') ?? params.get('error');
    const description = params.get('error_description');
    if (!code && !description) return '';

    if (code === 'otp_expired' || description?.toLowerCase().includes('expired')) {
      return 'ログインコードの有効期限が切れています。新しいコードを送信してください。';
    }
    return description ?? 'ログインに失敗しました。新しいコードを送信してください。';
  }

  async function requestOtp(normalizedEmail: string) {
    if (otpCooldownRemaining > 0) {
      setMessage(`${otpCooldownRemaining}秒後にもう一度送信できます。`);
      return;
    }

    setIsBusy(true);
    const { error } = await supabase.auth.signInWithOtp({
      email: normalizedEmail,
      options: {
        emailRedirectTo: roomURL(roomCode),
        shouldCreateUser: true,
      },
    });
    setIsBusy(false);

    if (error) {
      if (/rate limit|too many requests/i.test(error.message)) {
        setOtpCooldownRemaining(OTP_RESEND_COOLDOWN_SECONDS);
        setMessage('Supabaseのメール送信制限に達しました。パスワードログインを使うか、時間をおいて再送してください。');
      } else {
        setMessage(error.message);
      }
      return;
    }

    setOtpCooldownRemaining(OTP_RESEND_COOLDOWN_SECONDS);
    setSessionState('otp-sent');
    setMessage('メールに届いた最新の6桁コードを入力してください。');
  }

  async function sendOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');

    const normalizedEmail = email.trim().toLowerCase();
    if (!isAllowedMusabiEmail(normalizedEmail)) {
      setMessage('musabi.ac.jp またはそのサブドメインのメールアドレスを使ってください。');
      return;
    }

    await requestOtp(normalizedEmail);
  }

  async function signInWithPassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');

    const normalizedEmail = email.trim().toLowerCase();
    if (!isAllowedMusabiEmail(normalizedEmail)) {
      setMessage('musabi.ac.jp またはそのサブドメインのメールアドレスを使ってください。');
      return;
    }

    if (!password) {
      setMessage('パスワードを入力してください。');
      return;
    }

    setIsBusy(true);
    const { error } = await supabase.auth.signInWithPassword({
      email: normalizedEmail,
      password,
    });
    setIsBusy(false);

    if (error) {
      setMessage(error.message);
      return;
    }

    setPassword('');
    setSessionState('signed-in');
    setMessage('');
  }

  async function updatePassword(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');

    if (newPassword.length < 8) {
      setMessage('パスワードは8文字以上にしてください。');
      return;
    }
    if (newPassword !== newPasswordConfirmation) {
      setMessage('確認用パスワードが一致しません。');
      return;
    }

    setIsBusy(true);
    const { error } = await supabase.auth.updateUser({ password: newPassword });
    setIsBusy(false);

    if (error) {
      setMessage(error.message);
      return;
    }

    setNewPassword('');
    setNewPasswordConfirmation('');
    setIsPasswordRecovery(false);
    setPasswordRecoveryComplete(true);
    setSessionState('signed-in');
    window.history.replaceState({}, document.title, window.location.pathname);
    setMessage(roomCode ? 'パスワードを更新しました。' : 'パスワードを更新しました。投稿URLを開いてログインしてください。');
  }

  async function resendOtp() {
    setMessage('');
    const normalizedEmail = email.trim().toLowerCase();
    if (!isAllowedMusabiEmail(normalizedEmail)) {
      setSessionState('signed-out');
      setMessage('メールアドレスを入力し直してください。');
      return;
    }
    setOtp('');
    await requestOtp(normalizedEmail);
  }

  async function verifyOtp(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');
    setIsBusy(true);

    const normalizedEmail = email.trim().toLowerCase();
    const normalizedToken = normalizeOtpToken(otp);

    if (normalizedToken.length !== 6) {
      setIsBusy(false);
      setMessage('メールに届いた6桁コードを入力してください。');
      return;
    }

    const verifyTypes = ['email', 'signup'] as const;
    let lastError: Error | null = null;

    for (const type of verifyTypes) {
      const { error } = await supabase.auth.verifyOtp({
        email: normalizedEmail,
        token: normalizedToken,
        type,
      });

      if (!error) {
        setIsBusy(false);
        setSessionState('signed-in');
        setMessage('');
        return;
      }

      lastError = error;
      if (!/token|expired|invalid/i.test(error.message)) {
        break;
      }
    }

    setIsBusy(false);

    setMessage(lastError?.message ?? 'ログインコードを確認できませんでした。新しいコードを送信してください。');
  }

  async function submitComment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage('');

    const normalized = normalizeComment(comment);
    if (!normalized) {
      setMessage('コメントを入力してください。');
      return;
    }
    if (normalized.length > MAX_COMMENT_LENGTH) {
      setMessage(`${MAX_COMMENT_LENGTH}文字以内で入力してください。`);
      return;
    }

    setIsBusy(true);
    const { error } = await supabase.rpc('submit_room_comment', {
      p_room_code: roomCode,
      p_content: normalized,
    });
    setIsBusy(false);

    if (error) {
      setMessage(error.message);
      return;
    }

    setComment('');
    setMessage('送信しました。');
  }

  if (!roomCode && !isPasswordRecovery && !passwordRecoveryComplete) {
    return (
      <main className="shell">
        <section className="panel">
          <h1>Room not found</h1>
          <p>投稿URLを確認してください。</p>
        </section>
      </main>
    );
  }

  return (
    <main className="shell">
      <section className="panel">
        <p className="eyebrow">Screen Commentator</p>
        <h1>{isPasswordRecovery ? 'パスワード再設定' : passwordRecoveryComplete ? 'パスワード更新済み' : 'コメント投稿'}</h1>
        {roomCode && <p className="room">Room {roomCode}</p>}

        {passwordRecoveryComplete && !roomCode && (
          <p className="muted">投稿URLを開いてログインしてください。</p>
        )}

        {isPasswordRecovery && !passwordRecoveryComplete && (
          <form onSubmit={updatePassword} className="form">
            <label>
              新しいパスワード
              <input
                type="password"
                value={newPassword}
                onChange={(event) => setNewPassword(event.target.value)}
                autoComplete="new-password"
                minLength={8}
                required
              />
            </label>
            <label>
              新しいパスワード（確認）
              <input
                type="password"
                value={newPasswordConfirmation}
                onChange={(event) => setNewPasswordConfirmation(event.target.value)}
                autoComplete="new-password"
                minLength={8}
                required
              />
            </label>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '更新中...' : 'パスワードを更新'}
            </button>
          </form>
        )}

        {!isPasswordRecovery && sessionState === 'checking' && <p className="muted">確認中...</p>}

        {!isPasswordRecovery && sessionState === 'signed-out' && (
          <div className="auth-mode" role="tablist" aria-label="ログイン方法">
            <button
              type="button"
              className={authMode === 'otp' ? 'mode active' : 'mode'}
              onClick={() => {
                setAuthMode('otp');
                setMessage('');
              }}
            >
              メールコード
            </button>
            <button
              type="button"
              className={authMode === 'password' ? 'mode active' : 'mode'}
              onClick={() => {
                setAuthMode('password');
                setMessage('');
              }}
            >
              パスワード
            </button>
          </div>
        )}

        {!isPasswordRecovery && sessionState === 'signed-out' && authMode === 'password' && (
          <form onSubmit={signInWithPassword} className="form">
            <label>
              メールアドレス
              <input
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="name@ct.musabi.ac.jp"
                autoComplete="email"
                required
              />
            </label>
            <label>
              パスワード
              <input
                type="password"
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
                required
              />
            </label>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '確認中...' : 'ログイン'}
            </button>
          </form>
        )}

        {!isPasswordRecovery && sessionState === 'signed-out' && authMode === 'otp' && (
          <form onSubmit={sendOtp} className="form">
            <label>
              メールアドレス
              <input
                type="email"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="name@ct.musabi.ac.jp"
                autoComplete="email"
                required
              />
            </label>
            <button type="submit" disabled={isBusy || otpCooldownRemaining > 0}>
              {isBusy
                ? '送信中...'
                : otpCooldownRemaining > 0
                  ? `${otpCooldownRemaining}秒後に再送`
                  : 'コードを送信'}
            </button>
          </form>
        )}

        {!isPasswordRecovery && sessionState === 'otp-sent' && (
          <form onSubmit={verifyOtp} className="form">
            <label>
              6桁コード
              <input
                type="text"
                value={otp}
                onChange={(event) => setOtp(event.target.value)}
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={6}
                required
              />
            </label>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '確認中...' : 'ログイン'}
            </button>
            <button type="button" className="secondary" onClick={() => setSessionState('signed-out')}>
              メールを変更
            </button>
            <button type="button" className="secondary" onClick={resendOtp} disabled={isBusy || otpCooldownRemaining > 0}>
              {otpCooldownRemaining > 0 ? `${otpCooldownRemaining}秒後に再送` : 'コードを再送'}
            </button>
          </form>
        )}

        {!isPasswordRecovery && sessionState === 'signed-in' && roomCode && (
          <form onSubmit={submitComment} className="form">
            <label>
              コメント
              <textarea
                value={comment}
                onChange={(event) => setComment(event.target.value)}
                maxLength={MAX_COMMENT_LENGTH}
                rows={3}
                required
              />
            </label>
            <div className="counter">{normalizeComment(comment).length}/{MAX_COMMENT_LENGTH}</div>
            <button type="submit" disabled={isBusy}>
              {isBusy ? '送信中...' : '送信'}
            </button>
            <button type="button" className="secondary" onClick={() => supabase.auth.signOut()}>
              ログアウト
            </button>
          </form>
        )}

        {message && <p className="message">{message}</p>}
      </section>
    </main>
  );
}
