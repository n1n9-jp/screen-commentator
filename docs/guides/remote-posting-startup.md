# Remote Posting Startup Guide

Web投稿連携をローカルで検証するための起動手順です。npmはリポジトリ直下ではなく`web/`で実行し、Xcodeでは`ScreenCommentator.xcodeproj`を開きます。

## 1. Supabaseを設定する

Supabase Dashboardで対象Projectを開き、`SQL Editor`でmigrationを実行します。

1. `supabase/migrations/202606170001_remote_comments.sql`を実行
2. `supabase/migrations/202606220001_host_admin_tokens.sql`を実行
3. `supabase/migrations/202606220002_pgcrypto_schema.sql`を実行
4. `supabase/migrations/202606220003_disambiguate_submit_comment.sql`を実行

すでに1つ目と2つ目を実行済みなら、3つ目と4つ目だけ実行します。`column reference "created_at" is ambiguous`が出た場合は、4つ目のmigrationをSQL Editorで実行してください。

次に管理者トークンを登録します。`replace-with-a-long-random-token`は実際の長いランダム文字列に置き換えます。

```sql
insert into public.host_admin_tokens(token_hash, label)
values (
  encode(extensions.digest('replace-with-a-long-random-token', 'sha256'), 'hex'),
  'default admin token'
);
```

macOSアプリには、ハッシュではなく元の文字列を`Remote Posting > Host admin token`へ入力します。

## 2. Supabase Authを設定する

Email loginはSupabaseでは標準で有効なことが多いですが、以下を確認します。

- `Authentication`または`Auth` -> `Sign In / Providers` -> `Email`
- Email providerが有効
- 必要なら`Email OTP Expiration`を確認

メール内リンクの戻り先も許可します。

- `Authentication`または`Auth` -> `URL Configuration`
- Vercel本番で使う場合:
  - `Site URL`: `https://screen-commentator.vercel.app`
  - `Redirect URLs`: `https://screen-commentator.vercel.app/**`
- ローカル検証も使う場合は、追加で`http://localhost:5173/**`を`Redirect URLs`へ入れる
- `http://localhost:3000`はこのプロジェクトでは使っていないため、残っている場合は削除するか本番URLに置き換える

`Reset your password`メールのリンクが`redirect_to=http://localhost:3000`になっている場合、Supabase側の`Site URL`が古い値のままです。上記のURL設定を直した後、その古いリセットメールは破棄し、新しいリセットメールを発行し直してください。すでに送信済みのメール内リンクは、後からDashboard設定を直しても書き換わりません。

パスワード再設定リンクはルームURLではなくアプリのトップへ戻ることがあります。Web UIは再設定リンクで戻ってきた場合だけ、ルームコードなしでもパスワード更新画面を表示します。パスワード更新後は、投稿用URL`https://screen-commentator.vercel.app/r/ROOMCODE`を開いてログインします。

OTPメールは`Confirm sign up`ではなく、`Magic Link or OTP`テンプレートを編集します。

- `Authentication`または`Auth` -> `Emails`または`Email Templates`
- `Magic Link or OTP`を開く
- `{{ .ConfirmationURL }}`のリンク行を消し、`{{ .Token }}`を本文に出す

例:

```html
<h2>ログインコード</h2>
<p>以下の6桁コードを投稿画面に入力してください。</p>
<p style="font-size: 24px; font-weight: bold; letter-spacing: 4px;">{{ .Token }}</p>
```

`Token has expired or is invalid`が出た場合は、古いメールのコード、期限切れコード、または使用済みコードを使っています。投稿画面で`コードを再送`を押し、最新メールの6桁コードだけを入力してください。メール内にリンクが残っている場合でも、このWeb UIではリンクではなく6桁コードを使います。リンク方式にしたい場合は別実装になるため、`{{ .ConfirmationURL }}`はテンプレートから消しておきます。

`email rate limit exceeded`が出た場合は、Supabase Authのメール送信制限に達しています。Supabase Dashboardの`Authentication` -> `Rate Limits`で`Rate limit for sending emails`が`2 emails/h`かつ入力欄がdisabledになっている場合、Supabase標準メール送信の上限に当たっているためDashboardからは緩められません。この状態では`Send password recovery`、`Send magic link`、OTP送信のどれも失敗します。

この場合の回避策は次のどちらかです。

1. SupabaseにCustom SMTPを設定してメール送信上限を自分のSMTP側へ移す
2. 検証用ユーザーにパスワードを直接設定し、Web UIの`パスワード`ログインを使う

短時間の検証では2が早いです。SQL Editorで以下を実行します。`REPLACE_WITH_EMAIL`と`REPLACE_WITH_TEMP_PASSWORD`は実際の値に置き換えますが、実メールアドレスや実パスワードをリポジトリへコミットしないでください。

```sql
update auth.users
set
  encrypted_password = extensions.crypt('REPLACE_WITH_TEMP_PASSWORD', extensions.gen_salt('bf')),
  email_confirmed_at = coalesce(email_confirmed_at, now()),
  updated_at = now()
where lower(email) = lower('REPLACE_WITH_EMAIL')
returning id, email, email_confirmed_at, updated_at;
```

`returning`で対象ユーザーが1行返れば設定完了です。その後、投稿画面を再読み込みし、`パスワード`タブでログインします。対象ユーザーが返らない場合はメールアドレスが一致していません。

メール送信制限で検証できない場合は、Supabase Authにメール+パスワードのユーザーを用意します。Web UIは`パスワード`ログインにも対応しているため、パスワードログインではSupabaseからメールを送信しません。

テスト用アカウントを作り直してよい場合:

1. Supabase Dashboardで`Authentication` -> `Users`を開く
2. 対象メールアドレスの既存ユーザーを削除する
3. `Add user`または`Create user`で同じメールアドレスを作る
4. 任意の強いパスワードを設定する
5. `Auto Confirm User`または`Confirm email`相当の設定を有効にして作成する
6. 投稿画面で`パスワード`を選び、メールアドレスとパスワードでログインする

既存ユーザーを消したくない場合は、Supabaseの管理者APIでそのユーザーにパスワードを設定します。この場合は`service_role`キーが必要です。`service_role`キーはリポジトリやチャットに貼らず、ローカルの一時入力だけにしてください。

初めて使うメールアドレスでは、Supabaseが`Confirm your email address`という新規登録確認メールを送ることがあります。そのリンクを使う場合でも、Web UIはルームURLへ戻るように`/r/ROOMCODE`をredirect先に指定しています。リンク先が許可されない場合は、上の`Redirect URLs`設定を確認します。

新規ユーザー作成時のドメイン制限も設定します。

- `Authentication`または`Auth` -> `Auth Hooks`
- `Before User Created`を有効化
- Typeは`Postgres Function`
- Function指定欄がある場合は`public.hook_restrict_musabi_signup`
- URI指定欄の場合は`pg-functions://postgres/public/hook_restrict_musabi_signup`

投稿RPC側でも`musabi.ac.jp`と`*.musabi.ac.jp`以外は拒否しますが、Auth Hookも設定するとログイン作成前に弾けます。

## 3. Web UIを起動する

必ず`web/`へ移動してからnpmを実行します。

```bash
cd /Users/yuichiyazaki/Documents/GitHubRepository/Prj_App_OtherWorks/screen-commentator/web
cp .env.example .env
```

`.env`にSupabaseのProject URLとanon keyを入れます。

```bash
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

起動します。

```bash
npm install
npm run dev
```

表示されたURLを控えます。通常は以下です。

```text
http://localhost:5173
```

`Could not read package.json`が出た場合は、リポジトリ直下でnpmを実行しています。`web/`へ移動してやり直します。

### Vercelにデプロイする場合

VercelのProject設定は以下にします。

- `Root Directory`: `web`
- `Framework Preset`: `Vite`
- `Install Command`: `npm install`
- `Build Command`: `npm run build`
- `Output Directory`: `dist`

Environment Variablesには以下を登録します。

```text
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key
```

`/r/ROOMCODE`を直接開いたときに404にならないよう、`web/vercel.json`で全URLを`index.html`へ戻しています。このファイルが反映されるには、Vercelの`Root Directory`が必ず`web`である必要があります。

もしVercelの`Root Directory`をリポジトリ直下のまま使う場合は、リポジトリ直下の`vercel.json`が使われます。この場合も`/r/ROOMCODE`は`index.html`へrewriteされます。どちらの方式でも、`vercel.json`をGitHubへpushして再デプロイするまで本番には反映されません。

デプロイ後、Supabase Dashboard側もVercelのURLを許可します。

- `Authentication`または`Auth` -> `URL Configuration`
- `Site URL`: 本番で使うVercel URL。例: `https://screen-commentator.vercel.app`
- `Redirect URLs`: 本番URLに`/**`を付けて追加。例: `https://screen-commentator.vercel.app/**`
- `http://localhost:3000`が残っている場合は削除するか、本番URLに置き換える

macOSアプリ側の`Remote Posting > Vercel base URL`にも同じ本番URLを入れます。末尾の`/`は不要です。

## 4. macOSアプリを起動する

画面収録許可が必要なため、XcodeのRunではなく固定パスへインストールしたアプリを起動します。XcodeのDebug実行は署名・パスが変わり、macOSの画面収録許可が噛み合わないことがあります。

```bash
cd /Users/yuichiyazaki/Documents/GitHubRepository/Prj_App_OtherWorks/screen-commentator
chmod +x scripts/install-and-open-app.sh
./scripts/install-and-open-app.sh
```

このスクリプトはアプリをビルドし、既存の`~/Applications/ScreenCommentator.app`を自動で上書きして起動します。手動コピーは不要です。KeychainにApple Development証明書がある場合はそれで署名します。ない場合はローカルコード署名証明書を作って署名します。画面収録許可は署名に紐づくため、XcodeのRunやadhoc署名のアプリではなく、この固定パス・固定署名版で検証します。

初回はアプリ上部に表示される`Request Screen Recording`を押すか、`Start`を押して画面収録要求を発火させます。その後、macOSの`System Settings > Privacy & Security > Screen & System Audio Recording`で`ScreenCommentator`を許可します。許可後はアプリを一度終了してから、`~/Applications/ScreenCommentator.app`を開き直します。

許可済みに見えるのに`Start`できない場合は、`ScreenCommentator`の許可を一度OFFにしてONに戻し、アプリを終了して`~/Applications/ScreenCommentator.app`を開き直します。それでも変わらない場合は、古いDebugビルドへの許可が残っている可能性があるため、以下で画面収録許可をリセットしてからスクリプトを実行し直します。

```bash
tccutil reset ScreenCapture com.local.screencommentator
```

Runすると小さい設定ウィンドウが開きます。このウィンドウ内の設定リストを下へスクロールすると、`Blacklist Monitor`の下、`Appearance`の上に`REMOTE POSTING`という見出しがあります。ここが`Remote Posting`設定です。

`REMOTE POSTING`には以下を入力します。

- `Supabase URL`: Supabase Project URL
- `Supabase anon key`: Supabase anon public key。`anon`というラベル文字は入れず、`eyJ...`または`sb_publishable_...`で始まるキー本体だけを入れる
- `Vercel base URL`: ローカル検証なら`http://localhost:5173`
- `Host admin token`: Supabaseに登録した元の管理者トークン文字列

ここからの順番が重要です。

1. `Create`を押す
2. `Room code`と`Host token`が自動入力されることを確認する
3. 表示された投稿URLをコピーする
4. `Remote Posting > Enable`がONであることを確認する
5. その後にアプリ上部の`Start`を押す

`Start`は`Create`後、`Enable`をONにした後に押します。`Room code`と`Host token`がない状態で`Start`しても、Web投稿は取得できません。

`Start`でAI画面キャプチャとWeb投稿の取得が始まります。画面収録許可が通っていない場合、AIコメントは生成できないためStartしません。

AIコメントだけを止めたい場合は、設定ウィンドウの`AI Comments > Enable`をOFFにします。この場合、`Remote Posting > Enable`がONなら、`Start`でWeb投稿だけを取得して流します。AIコメントOFF時は画面収録を使わないため、画面収録許可は不要です。

Ollamaを使う場合は、設定ウィンドウの`AI Comments > Provider`を`Ollama (Local)`にし、`Model`には実際にインストール済みのモデルを選びます。インストール済みモデルは以下で確認できます。

```bash
ollama list
```

`Model`で選んだ値が`ollama list`にない場合、AIコメント生成は失敗します。このアプリはインストール済みの対応モデルが見つかる場合、自動でそちらへ切り替えます。例として`gemma4:e4b`が入っている環境では、軽い`Gemma 4 E4B`を優先して使います。`qwen2.5vl:32b`も画像対応ですが、MacBook Airでは重いことがあります。

Web投稿が流れない場合は、`Remote Posting`欄の表示を確認します。`Polling off`なら`Enable`がOFFです。`Start`後に`Fetch Now`を押すと、その時点でSupabaseから新規コメントを手動取得し、`no new comments`または取得件数を表示します。

## 5. 投稿を検証する

投稿URLをブラウザで開きます。

```text
http://localhost:5173/r/ROOMCODE
```

許可されるメールの例:

```text
user@musabi.ac.jp
user@ct.musabi.ac.jp
user@fs.musabi.ac.jp
```

拒否されるメールの例:

```text
user@gmail.com
user@evil-musabi.ac.jp
user@musabi.ac.jp.example.com
```

macOSアプリ側で`Start`済みの状態にしてから、Web投稿画面からコメントを送ります。

通常時はAIコメントとWeb投稿コメントが同じ見た目で流れます。`Control + Option + Command`を押している間だけ、AI投稿が青、ユーザー投稿が黄になります。

## 6. 最終確認コマンド

Web:

```bash
cd /Users/yuichiyazaki/Documents/GitHubRepository/Prj_App_OtherWorks/screen-commentator/web
npm run build
```

macOS:

```bash
cd /Users/yuichiyazaki/Documents/GitHubRepository/Prj_App_OtherWorks/screen-commentator
xcodebuild -project ScreenCommentator.xcodeproj -scheme ScreenCommentator -destination 'platform=macOS' -derivedDataPath DerivedData build
```
