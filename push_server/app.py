import os
import datetime
import json
import hmac
import hashlib
import logging
from flask import Flask, request, jsonify, abort
import requests
from peewee import (
    SqliteDatabase,
    Model,
    IntegerField,
    CharField,
    DateTimeField,
    BigAutoField,
)
from apscheduler.schedulers.background import BackgroundScheduler

# --- 全局变量 ---
TELEGRAM_BOT_TOKEN = None
WEBHOOK_SECRET = None
TARGETS = []
GITHUB_TARGET_USER = 'YuzakiKokuban'
DB_FILE = "sent_messages.db"
CONFIG_FILE = "config.json"
CLEANUP_DAYS = 7

http_session = requests.Session()
FILE_ID_CACHE = {}
app = Flask(__name__)

# --- 日志配置 ---
# 移除 Flask 默认的 handler，使用我们自己的
app.logger.removeHandler(app.logger.handlers[0]) 
logging.basicConfig(level=logging.INFO,
                    format='[%(asctime)s] [%(levelname)s] - %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S')

# --- 加载配置的函数 ---
def load_config():
    global TARGETS, TELEGRAM_BOT_TOKEN, WEBHOOK_SECRET
    try:
        with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
            config_data = json.load(f)
            TARGETS = config_data.get('targets', [])
            TELEGRAM_BOT_TOKEN = config_data.get('telegram_bot_token')
            WEBHOOK_SECRET = config_data.get('webhook_secret')
            
            logging.info(f"成功从 {CONFIG_FILE} 加载了配置喵~")
            if not TELEGRAM_BOT_TOKEN or 'placeholder' in TELEGRAM_BOT_TOKEN:
                logging.warning("telegram_bot_token 未在 config.json 中正确配置！")
            if not WEBHOOK_SECRET or 'placeholder' in WEBHOOK_SECRET:
                logging.warning("webhook_secret 未在 config.json 中正确配置！签名验证将不会启用。")

    except Exception as e:
        logging.error(f"加载配置文件 {CONFIG_FILE} 出错: {e}", exc_info=True)
        TARGETS, TELEGRAM_BOT_TOKEN, WEBHOOK_SECRET = [], None, None

# --- 数据库设置 ---
db = SqliteDatabase(DB_FILE)

class SentMessage(Model):
    id = BigAutoField(primary_key=True)
    chat_id = CharField()
    message_id = IntegerField()
    sent_at = DateTimeField(default=datetime.datetime.now)

    class Meta:
        database = db

# --- 消息发送函数 ---
def send_message_to_target(message, target_config):
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    params = {'chat_id': target_config['chat_id'], 'text': message, 'parse_mode': 'Markdown'}
    if 'message_thread_id' in target_config:
        params['message_thread_id'] = target_config['message_thread_id']
    try:
        response = http_session.post(api_url, json=params, timeout=10)
        response.raise_for_status(); response_data = response.json()
        logging.info(f"文本消息成功发送到 {target_config['chat_id']} 喵~")
        return response_data['result']['message_id']
    except (requests.exceptions.RequestException, KeyError) as e:
        logging.error(f"发送文本消息到 {target_config['chat_id']} 时出错啦: {e}", exc_info=True)
        return None

def upload_document_and_get_id(caption, file_stream, file_name, target_config):
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument"
    params = {'chat_id': target_config['chat_id'], 'caption': caption, 'parse_mode': 'Markdown'}
    if 'message_thread_id' in target_config:
        params['message_thread_id'] = target_config['message_thread_id']
    files = {'document': (file_name, file_stream)}
    try:
        response = http_session.post(api_url, data=params, files=files, timeout=180)
        response.raise_for_status(); response_data = response.json()
        file_id = response_data['result']['document']['file_id']
        message_id = response_data['result']['message_id']
        logging.info(f"文件 '{file_name}' 成功上传，拿到 file_id 和 message_id 啦")
        return file_id, message_id
    except (requests.exceptions.RequestException, KeyError) as e:
        logging.error(f"上传文件并获取 id 时出错: {e}", exc_info=True)
        return None, None

def send_document_by_id(caption, file_id, target_config):
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendDocument"
    params = {'chat_id': target_config['chat_id'], 'document': file_id, 'caption': caption, 'parse_mode': 'Markdown'}
    if 'message_thread_id' in target_config:
        params['message_thread_id'] = target_config['message_thread_id']
    try:
        response = http_session.post(api_url, json=params, timeout=10)
        response.raise_for_status(); response_data = response.json()
        logging.info(f"用 file_id 成功发送文件到 {target_config['chat_id']} 啦~")
        return response_data['result']['message_id']
    except (requests.exceptions.RequestException, KeyError) as e:
        logging.error(f"用 file_id 发送文件到 {target_config['chat_id']} 时出错惹: {e}", exc_info=True)
        return None

# --- 清理旧消息的函数 ---
def cleanup_old_messages():
    logging.info("--- 开始执行每日清理任务喵 ---")
    cleanup_threshold = datetime.datetime.now() - datetime.timedelta(days=CLEANUP_DAYS)
    old_messages = SentMessage.select().where(SentMessage.sent_at < cleanup_threshold)
    if not old_messages:
        logging.info("没有找到需要清理的旧消息哦~")
        return
    count = 0
    for msg in old_messages:
        try:
            api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/deleteMessage"
            params = {'chat_id': msg.chat_id, 'message_id': msg.message_id}
            response = http_session.post(api_url, json=params, timeout=10)
            if response.status_code == 200 or response.status_code == 400:
                logging.info(f"成功删除消息 (ID: {msg.message_id}) 或消息已不存在。")
                msg.delete_instance(); count += 1
            else: response.raise_for_status()
        except requests.exceptions.RequestException as e:
            logging.error(f"删除消息 (ID: {msg.message_id}) 时出错: {e}", exc_info=True)
    logging.info(f"清理任务完成，一共清理了 {count} 条旧消息喵！")

@app.route('/webhook', methods=['POST'])
def github_webhook():
    logging.info(f"--- 收到一个新的 Webhook 请求喵 (来自 {request.remote_addr}) ---")

    # --- Webhook 签名验证 ---
    if WEBHOOK_SECRET and 'placeholder' not in WEBHOOK_SECRET:
        signature = request.headers.get('X-Hub-Signature-256')
        if not signature:
            logging.warning("请求缺少 X-Hub-Signature-256 请求头，拒绝访问！")
            abort(403)
        sha_name, signature_hex = signature.split('=', 1)
        if sha_name != 'sha256':
            logging.warning(f"签名算法不是 sha256 ({sha_name})，拒绝访问！")
            abort(403)
        mac = hmac.new(WEBHOOK_SECRET.encode('utf-8'), msg=request.data, digestmod=hashlib.sha256)
        if not hmac.compare_digest(mac.hexdigest(), signature_hex):
            logging.warning("签名验证失败，拒绝访问！")
            abort(403)
        logging.info("签名验证成功喵~ 是主人发的请求！")
    else:
        logging.warning("WEBHOOK_SECRET 未配置，跳过签名验证。")

    if not TARGETS:
        logging.warning("没有配置任何推送目标，忽略此请求。")
        return jsonify({'status': 'ignored', 'reason': 'no targets configured'}), 200

    if request.headers.get('X-GitHub-Event') != 'release':
        return jsonify({'status': 'ignored'}), 200

    data = request.json
    
    try:
        if data['repository']['owner']['login'].lower() != GITHUB_TARGET_USER.lower():
            return jsonify({'status': 'ignored'}), 200
    except KeyError:
         logging.error("收到的 payload 格式不正确。", exc_info=True)
         return jsonify({'status': 'error', 'message': 'Malformed payload'}), 400

    if data.get('action') == 'published':
        try:
            repo_name = data['repository']['full_name']; release_info = data['release']
            tag_name = release_info['tag_name']; release_url = release_info['html_url']
            author = release_info['author']['login']; release_name = release_info['name'] or 'N/A'
            logging.info(f"是 'release' 的 'published' 动作耶，开始为 {repo_name} @ {tag_name} 工作喵！")
            
            message = (f"主人，主人~ 快来看喵！💖\n`{repo_name}` 有新宝贝发布啦~✨\n\n"
                       f"*版本是 (Version)*: `{tag_name}` 哦！\n*它的名字叫 (Title)*: {release_name}\n"
                       f"*是* `{author}` *主人做的喵！ (Author)*\n\n快去看看吧~ [（ฅ'ω'ฅ）点我去看]({release_url})")
            
            for target in TARGETS:
                if 'filter_tag' in target and target['filter_tag'].lower() not in tag_name.lower():
                    logging.info(f"跳过目标 {target['chat_id']}，因为 release tag '{tag_name}' 不包含 '{target['filter_tag']}'。")
                    continue
                message_id = send_message_to_target(message, target)
                if message_id: SentMessage.create(chat_id=target['chat_id'], message_id=message_id)
            
            assets = release_info.get('assets', [])
            if not assets:
                logging.info("这个 Release 没有附件喵。")
                return jsonify({'status': 'success'}), 200

            logging.info(f"发现 {len(assets)} 个附件，我来处理一下~")
            for asset in assets:
                asset_name = asset['name']; asset_url = asset['browser_download_url']; asset_size = asset['size']
                if asset_size > 50 * 1024 * 1024:
                    logging.warning(f"跳过附件 '{asset_name}'，因为它太大了喵 (> 50MB)。")
                    continue
                
                if '.' in asset_name: parts = asset_name.rsplit('.', 1); sanitized_name = f"{parts[0].replace('.', '-')}.{parts[1]}"
                else: sanitized_name = asset_name.replace('.', '-')
                
                if sanitized_name != asset_name:
                    logging.info(f"文件名被我变干净了喵: '{asset_name}' -> '{sanitized_name}'")
                
                file_caption = (f"主人，这是你的快递喵！📦\n*来自仓库 (Repo)*: `{repo_name}`\n"
                                f"*版本号 (Version)*: `{tag_name}`\n\n📄 *文件 (File)*: `{sanitized_name}`")
                
                targets_for_asset = [t for t in TARGETS if 'filter_tag' not in t or t['filter_tag'].lower() in tag_name.lower()]
                
                cached_file_id = FILE_ID_CACHE.get(asset_url)
                if cached_file_id:
                    logging.info(f"发现缓存的 file_id，直接发给你哦~")
                    for target in targets_for_asset:
                        message_id = send_document_by_id(file_caption, cached_file_id, target)
                        if message_id: SentMessage.create(chat_id=target['chat_id'], message_id=message_id)
                else:
                    logging.info(f"没找到缓存，现在去下载文件 '{asset_name}' 喵...")
                    try:
                        download_response = http_session.get(asset_url, stream=True, timeout=60, allow_redirects=True)
                        download_response.raise_for_status()
                        if targets_for_asset:
                            new_file_id, message_id = upload_document_and_get_id(file_caption, download_response.raw, sanitized_name, targets_for_asset[0])
                            if new_file_id:
                                FILE_ID_CACHE[asset_url] = new_file_id
                                if message_id: SentMessage.create(chat_id=targets_for_asset[0]['chat_id'], message_id=message_id)
                                for i in range(1, len(targets_for_asset)):
                                    message_id = send_document_by_id(file_caption, new_file_id, targets_for_asset[i])
                                    if message_id: SentMessage.create(chat_id=targets_for_asset[i]['chat_id'], message_id=message_id)
                    except requests.exceptions.RequestException as e:
                        logging.error(f"处理附件 '{asset_name}' 时出错惹: {e}", exc_info=True)
            
            return jsonify({'status': 'success'}), 200
        except KeyError as e:
            logging.error(f"解析 payload 出错惹: {e}", exc_info=True)
            return jsonify({'status': 'error'}), 400
    
    return jsonify({'status': 'ignored'}), 200

@app.route('/')
def index():
    return f"GitHub Release Bot for {GITHUB_TARGET_USER} is running! 喵~"

# --- 主程序入口 ---
if __name__ != '__main__':
    load_config()
    logging.info("初始化数据库和定时任务喵...")
    db.connect(reuse_if_open=True)
    db.create_tables([SentMessage], safe=True)
    scheduler = BackgroundScheduler(daemon=True, timezone="UTC")
    scheduler.add_job(cleanup_old_messages, 'interval', days=1)
    scheduler.start()
    logging.info("定时清理任务已经启动啦，我会每天打扫卫生的~")
