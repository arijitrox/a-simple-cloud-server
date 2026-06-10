import time
import os
import boto3
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# --- CONFIGURATION ---
# CHANGE THIS to the actual folder on your Gaming PC where logs appear
WATCH_DIRECTORY = r"C:\Users\arijit\Desktop\AMD_Logs" 

MINIO_URL = os.environ.get('MINIO_URL', 'http://localhost:9000')
ACCESS_KEY = os.environ.get('MINIO_ROOT_USER', '')
SECRET_KEY = os.environ.get('MINIO_ROOT_PASSWORD', '')
BUCKET_NAME = os.environ.get('MINIO_BUCKET', 'lab-logs')

class LogHandler(FileSystemEventHandler):
    def on_created(self, event):
        # Triggered when a file is created
        if not event.is_directory:
            print(f"👀 New file detected: {event.src_path}")
            # Wait a second to ensure file write is complete
            time.sleep(1)
            upload_to_minio(event.src_path)

def upload_to_minio(file_path):
    s3 = boto3.client('s3',
                      endpoint_url=MINIO_URL,
                      aws_access_key_id=ACCESS_KEY,
                      aws_secret_access_key=SECRET_KEY)
    
    file_name = os.path.basename(file_path)

    try:
        print(f"🚀 Uploading {file_name} to Lake...")
        s3.upload_file(file_path, BUCKET_NAME, file_name)
        print(f"✅ {file_name} secured in Data Lake.")
        
        # Optional: Move file to an 'Archive' folder locally so we don't re-upload?
        # shutil.move(file_path, os.path.join(WATCH_DIRECTORY, "archived", file_name))
        
    except Exception as e:
        print(f"❌ Failed to upload {file_name}: {e}")

if __name__ == "__main__":
    # Ensure the watch directory exists
    if not os.path.exists(WATCH_DIRECTORY):
        os.makedirs(WATCH_DIRECTORY)
        print(f"📁 Created watch directory: {WATCH_DIRECTORY}")

    event_handler = LogHandler()
    observer = Observer()
    observer.schedule(event_handler, WATCH_DIRECTORY, recursive=False)
    observer.start()

    print(f"🦅 The Ingester is watching: {WATCH_DIRECTORY}")
    print("Press Ctrl+C to stop.")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()