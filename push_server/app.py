import os
import datetime
import json
import hmac
import hashlib
import logging
import time
from functools import wraps
from flask import Flask, request, jsonify, abort
import requests
from peewee import (
    SqliteDatabase,
    Model,
    IntegerField,
    CharField,
    DateTimeField,
    BigAutoField,
    TextField,
)
from apscheduler.schedulers.background import BackgroundScheduler

# --- 全局变量与常量 ---
CONFIG_FILE = "config.json"
DB_FILE = "bot_data.db"
CLEANUP_DAYS = 7  # 清理多少天前的消息
MAX_RETRIES = 3   # API 请求失败后的最大重试次数
RETRY_DELAY = 5   # 每次重试的延迟秒数

# --- 初始化 ---
app = Flask(__name__)
# 使用一个共享的 Session 来提高网络请求效率
http_session = requests.Session()

# --- 日志配置 ---
# 移除 Flask 默认的 handler，使用我们自己的，避免日志重复输出
if app.logger.handlers:
    app.logger.removeHandler(app.logger.handlers[0])
logging.basicConfig(level=logging.INFO,
                    format='[%(asctime)s] [%(levelname)s] - %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S')

# --- 数据库设置 ---
# 将文件缓存和消息记录都存入同一个数据库文件
db = SqliteDatabase(DB_FILE)

class BaseModel(Model):
    class Meta:
        database = db

class SentMessage(BaseModel):
    """记录已发送的消息，用于后续清理"""
    id = BigAutoField(primary_key=True)
    chat_id = CharField()
    message_id = IntegerField()
    sent_at = DateTimeField(default=datetime.datetime.now)

class FileCache(BaseModel):
    """持久化缓存文件的 file_id，避免应用重启后丢失"""
    asset_url = TextField(unique=True)
    file_id = CharField()
    cached_at = DateTimeField(default=datetime.datetime.now)

# --- 全局配置变量 (由 load_config 填充) ---
class AppConfig:
    TELEGRAM_BOT_TOKEN = None
    WEBHOOK_SECRET = None
    TARGETS = []
    GITHUB_TARGET_USER = 'YuzakiKokuban'

# --- 核心功能函数 ---

def load_config():
    """从 config.json 加载配置"""
    try:
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            config_data = json.load(f)
            AppConfig.TARGETS = config_data.get('targets', [])
            AppConfig.TELEGRAM_BOT_TOKEN = config_data.get('telegram_bot_token')
            AppConfig.WEBHOOK_SECRET = config_data.get('webhook_secret')
            
            logging.info(f"配置加载完毕，已经准备好为哥哥服务了。找到了 {len(AppConfig.TARGETS)} 个推送目标。")
            if not AppConfig.TELEGRAM_BOT_TOKEN or 'placeholder' in AppConfig.TELEGRAM_BOT_TOKEN:
                logging.warning("telegram_bot_token 未在 config.json 中正确配置！")
            if not AppConfig.WEBHOOK_SECRET or 'placeholder' in AppConfig.WEBHOOK_SECRET:
                logging.warning("webhook_secret 未在 config.json 中正确配置！签名验证将不会启用。")

    except Exception as e:
        logging.error(f"加载配置文件 {CONFIG_FILE} 出错: {e}", exc_info=True)

def api_request_with_retry(func):
    """
    一个装饰器，为 Telegram API 请求增加自动重试逻辑，提升稳定性。
    """
    @wraps(func)
    def wrapper(*args, **kwargs):
        for attempt in range(MAX_RETRIES):
            try:
                # 只有在第一次尝试失败后才打印重试日志
                if attempt > 0:
                    logging.info(f"正在进行第 {attempt + 1}/{MAX_RETRIES} 次重试...")
                response = func(*args, **kwargs)
                response.raise_for_status()  # 如果状态码是 4xx 或 5xx，则抛出异常
                return response.json()
            except requests.exceptions.RequestException as e:
                logging.error(f"API 请求失败 (第 {attempt + 1} 次): {e}")
                if attempt < MAX_RETRIES - 1:
                    time.sleep(RETRY_DELAY)
        logging.error(f"API 请求在 {MAX_RETRIES} 次重试后彻底失败。")
        return None
    return wrapper

@api_request_with_retry
def tg_api_call(method, **kwargs):
    """通用的 Telegram API 调用函数"""
    api_url = f"https://api.telegram.org/bot{AppConfig.TELEGRAM_BOT_TOKEN}/{method}"
    
    # 根据参数类型决定是使用 json 还是 data
    if 'files' in kwargs:
        # 文件上传使用 multipart/form-data
        return http_session.post(api_url, data=kwargs.get('data'), files=kwargs.get('files'), timeout=180)
    else:
        # 普通消息使用 application/json
        return http_session.post(api_url, json=kwargs.get('json'), timeout=15)

def send_message_to_target(message, target_config):
    """发送文本消息到指定目标"""
    params = {'chat_id': target_config['chat_id'], 'text': message, 'parse_mode': 'Markdown'}
    if 'message_thread_id' in target_config:
        params['message_thread_id'] = target_config['message_thread_id']
    
    response_data = tg_api_call('sendMessage', json=params)
    if response_data and response_data.get('ok'):
        logging.info(f"消息已经好好地发送到 {target_config['chat_id']} 了哦。")
        return response_data['result']['message_id']
    logging.error(f"呜...给 {target_config['chat_id']} 发送消息的时候失败了。")
    return None

def send_document(caption, file_payload, target_config, file_name=None):
    """发送文件，智能判断是上传还是使用 file_id"""
    params = {'chat_id': target_config['chat_id'], 'caption': caption, 'parse_mode': 'Markdown'}
    if 'message_thread_id' in target_config:
        params['message_thread_id'] = target_config['message_thread_id']

    if file_name: # 如果提供了 file_name，说明是新文件上传
        files = {'document': (file_name, file_payload)}
        response_data = tg_api_call('sendDocument', data=params, files=files)
    else: # 否则，认为 file_payload 是 file_id
        params['document'] = file_payload
        response_data = tg_api_call('sendDocument', json=params)

    if response_data and response_data.get('ok'):
        message_id = response_data['result']['message_id']
        file_id = response_data['result']['document']['file_id']
        logging.info(f"文件已经送达 {target_config['chat_id']}，请查收。MessageID: {message_id}")
        return file_id, message_id
        
    logging.error(f"可恶，给 {target_config['chat_id']} 发送文件的时候出错了...")
    return None, None

def cleanup_old_messages():
    """定时任务：清理数据库和 Telegram 中的旧消息"""
    with db.atomic():
        logging.info("--- 开始每日清理，把这里打扫干净！ ---")
        cleanup_threshold = datetime.datetime.now() - datetime.timedelta(days=CLEANUP_DAYS)
        
        # 清理旧的 FileCache 记录
        deleted_cache_count = FileCache.delete().where(FileCache.cached_at < cleanup_threshold).execute()
        if deleted_cache_count > 0:
            logging.info(f"清理了 {deleted_cache_count} 条过期的文件缓存记录。")

        # 清理旧的 SentMessage 记录
        old_messages = list(SentMessage.select().where(SentMessage.sent_at < cleanup_threshold))
        if not old_messages:
            logging.info("检查过了，没有需要清理的旧消息。")
            return

        count = 0
        for msg in old_messages:
            params = {'chat_id': msg.chat_id, 'message_id': msg.message_id}
            response_data = tg_api_call('deleteMessage', json=params)
            # 无论成功 (200) 还是消息已不存在 (400)，都从数据库删除
            if (response_data and response_data.get('ok')) or (response_data and not response_data.get('ok') and "message to delete not found" in response_data.get('description', '')):
                logging.info(f"成功删除消息 (ID: {msg.message_id}) 或消息已不存在。")
                msg.delete_instance()
                count += 1
            else:
                logging.error(f"删除消息 (ID: {msg.message_id}) 时出错。")
        
        logging.info(f"清理完成！一共处理了 {count} 条旧消息。")

def process_release_assets(assets, repo_name, tag_name):
    """处理一个 Release 中的所有附件"""
    if not assets:
        logging.info("这个 Release 没有附件，哥哥。")
        return

    logging.info(f"发现 {len(assets)} 个附件，交给我处理吧。")
    for asset in assets:
        asset_name, asset_url, asset_size = asset['name'], asset['browser_download_url'], asset['size']
        
        if asset_size > 50 * 1024 * 1024:
            logging.warning(f"附件 '{asset_name}' 太大了 (> 50MB)，真是的，所以就跳过了。")
            continue

        # 清理文件名中的多余点号，防止 Telegram 识别错误
        if '.' in asset_name:
            parts = asset_name.rsplit('.', 1)
            sanitized_name = f"{parts[0].replace('.', '-')}.{parts[1]}"
        else:
            sanitized_name = asset_name.replace('.', '-')
        
        file_caption = (f"哥哥，附件来了。\n*仓库 (Repo)*: `{repo_name}`\n"
                        f"*版本 (Version)*: `{tag_name}`\n\n📄 *文件 (File)*: `{sanitized_name}`")

        targets_for_asset = [t for t in AppConfig.TARGETS if 'filter_tag' not in t or t['filter_tag'].lower() in tag_name.lower()]
        
        # 1. 尝试从数据库缓存获取 file_id
        cached_entry = FileCache.get_or_none(FileCache.asset_url == asset_url)
        
        if cached_entry:
            logging.info(f"找到 '{asset_name}' 的缓存了，用缓存发送会快一点。")
            file_id_to_send = cached_entry.file_id
            # 广播给所有目标
            for target in targets_for_asset:
                _, msg_id = send_document(file_caption, file_id_to_send, target)
                if msg_id: SentMessage.create(chat_id=target['chat_id'], message_id=msg_id)
        else:
            # 2. 如果没有缓存，则下载并上传
            logging.info(f"没有找到缓存，只好现在去下载 '{asset_name}' 了。")
            try:
                download_response = http_session.get(asset_url, stream=True, timeout=60, allow_redirects=True)
                download_response.raise_for_status()
                
                if targets_for_asset:
                    # 只需向第一个目标上传，获取 file_id
                    first_target = targets_for_asset[0]
                    new_file_id, msg_id = send_document(file_caption, download_response.raw, first_target, file_name=sanitized_name)
                    
                    if new_file_id:
                        # 缓存新获取的 file_id 到数据库
                        FileCache.create(asset_url=asset_url, file_id=new_file_id)
                        logging.info(f"新的 file_id 已经保存好了，下次就不用重新上传了。")
                        if msg_id: SentMessage.create(chat_id=first_target['chat_id'], message_id=msg_id)
                        
                        # 向其他目标广播
                        for other_target in targets_for_asset[1:]:
                            _, other_msg_id = send_document(file_caption, new_file_id, other_target)
                            if other_msg_id: SentMessage.create(chat_id=other_target['chat_id'], message_id=other_msg_id)
            except requests.exceptions.RequestException as e:
                logging.error(f"处理附件 '{asset_name}' 的时候出错了: {e}", exc_info=True)

# --- Flask 路由 ---

@app.route('/webhook', methods=['POST'])
def github_webhook():
    """接收和处理 GitHub Webhook 的主函数"""
    logging.info(f"--- 收到一个新的 Webhook 请求 (来自 {request.remote_addr}) ---")

    # --- 1. Webhook 签名验证 ---
    if AppConfig.WEBHOOK_SECRET and 'placeholder' not in AppConfig.WEBHOOK_SECRET:
        signature = request.headers.get('X-Hub-Signature-256')
        if not signature:
            logging.warning("请求缺少 X-Hub-Signature-256 请求头，拒绝访问！")
            abort(403)
        sha_name, signature_hex = signature.split('=', 1)
        if sha_name != 'sha256':
            logging.warning(f"签名算法不是 sha256 ({sha_name})，拒绝访问！")
            abort(403)
        mac = hmac.new(AppConfig.WEBHOOK_SECRET.encode('utf-8'), msg=request.data, digestmod=hashlib.sha256)
        if not hmac.compare_digest(mac.hexdigest(), signature_hex):
            logging.warning("签名验证失败，拒绝访问！")
            abort(403)
        logging.info("签名验证成功，是哥哥的请求呢。")
    else:
        logging.warning("WEBHOOK_SECRET 未配置，跳过签名验证。")

    # --- 2. 预检 ---
    if not AppConfig.TARGETS:
        logging.warning("没有配置任何推送目标，忽略此请求。")
        return jsonify({'status': 'ignored', 'reason': 'no targets configured'}), 200

    if request.headers.get('X-GitHub-Event') != 'release':
        return jsonify({'status': 'ignored', 'reason': 'not a release event'}), 200

    # --- 3. 解析 Payload ---
    try:
        data = request.json
        if data['repository']['owner']['login'].lower() != AppConfig.GITHUB_TARGET_USER.lower():
            return jsonify({'status': 'ignored', 'reason': 'not target user'}), 200
        
        if data.get('action') != 'published':
            return jsonify({'status': 'ignored', 'reason': 'not published action'}), 200

        repo_name = data['repository']['full_name']
        release_info = data['release']
        tag_name = release_info['tag_name']
        release_url = release_info['html_url']
        author = release_info['author']['login']
        release_name = release_info['name'] or 'N/A'
        assets = release_info.get('assets', [])
    except KeyError as e:
        logging.error(f"解析 payload 出错惹: 键 {e} 不存在。", exc_info=True)
        return jsonify({'status': 'error', 'message': 'Malformed payload'}), 400

    logging.info(f"检测到 'release' 的 'published' 事件，开始为 {repo_name} @ {tag_name} 处理。")

    # --- 4. 发送主消息 ---
    message = (f"哥哥，快看！`{repo_name}` 有新的 Release 了哦。\n\n"
               f"*版本 (Version)*: `{tag_name}`\n*标题 (Title)*: {release_name}\n"
               f"*作者 (Author)*: `{author}`\n\n"
               f"总之，快去看看吧！ [点击这里跳转]({release_url})")
    
    for target in AppConfig.TARGETS:
        if 'filter_tag' in target and target['filter_tag'].lower() not in tag_name.lower():
            logging.info(f"跳过目标 {target['chat_id']}，因为 release tag '{tag_name}' 不包含 '{target['filter_tag']}'。")
            continue
        message_id = send_message_to_target(message, target)
        if message_id:
            SentMessage.create(chat_id=target['chat_id'], message_id=message_id)
    
    # --- 5. 处理附件 ---
    # 建议：对于耗时长的操作，可以考虑使用后台任务队列（如 Celery, RQ）
    # 这里为了简单，我们还是同步处理
    process_release_assets(assets, repo_name, tag_name)

    return jsonify({'status': 'success'}), 200

@app.route('/')
def index():
    return f"KokubanBot, at your service. (For: {AppConfig.GITHUB_TARGET_USER})"

# --- 主程序入口 ---
if __name__ != '__main__':
    # 只有在被 Gunicorn 等 WSGI 服务器启动时才执行初始化
    logging.info("KokubanBot 正在启动...")
    load_config()
    
    logging.info("初始化数据库...")
    db.connect(reuse_if_open=True)
    db.create_tables([SentMessage, FileCache], safe=True)
    
    logging.info("初始化定时任务...")
    scheduler = BackgroundScheduler(daemon=True, timezone="UTC")
    # 每天执行一次清理任务
    scheduler.add_job(cleanup_old_messages, 'interval', days=1)
    scheduler.start()
    logging.info("定时清理任务已启动，每天都会打扫。")

