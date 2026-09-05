import os, tempfile
from fastapi import FastAPI, UploadFile, File, HTTPException
from faster_whisper import WhisperModel

app=FastAPI(title="Assis SmartFlow STT", version="1.0.0")
MODEL_NAME=os.getenv("WHISPER_MODEL","small")
model=WhisperModel(MODEL_NAME, device=os.getenv("WHISPER_DEVICE","cpu"), compute_type=os.getenv("WHISPER_COMPUTE_TYPE","int8"))

@app.get("/health")
def health(): return {"status":"ok","model":MODEL_NAME}

@app.post("/v1/transcribe")
async def transcribe(file: UploadFile=File(...), language: str="pt"):
    suffix=os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await file.read()); path=tmp.name
    try:
        segments, info=model.transcribe(path, language=language, vad_filter=True, beam_size=5)
        segs=[{"start":s.start,"end":s.end,"text":s.text.strip()} for s in segments]
        text=" ".join(x["text"] for x in segs).strip()
        return {"text":text,"language":info.language,"duration":info.duration,"segments":segs,"model":MODEL_NAME}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    finally:
        try: os.unlink(path)
        except OSError: pass
