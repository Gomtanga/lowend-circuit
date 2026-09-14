# LowEnd Circuit — Windows WASAPI 계약 (Phase 2)

이 문서는 `Windows/Source/AudioEngine/Devices.h`의 **동결된 계약**이다.
구현자는 이 계약을 그대로 만족해야 하며, 헤더 시그니처를 바꾸지 않는다.

## 1. 목표

Windows에서 시스템 오디오(루프백) 또는 입력 장치를 캡처해 DSP로 처리하고 출력 장치로 보낸다.
WASAPI shared mode만 사용한다. exclusive mode는 구현하지 않는다.

## 2. 장치 열거 (control thread)

`listDevices(DataFlow, std::string& error)`:

- COM을 이미 초기화했다고 가정하지 말고, 필요하면 `CoInitializeEx(nullptr, COINIT_MULTITHREADED)`를
  호출하되 **이미 다른 apartment로 초기화된 경우 `RPC_E_CHANGED_MODE`를 실패로 취급하지 않는다**.
  반환 시 자신이 초기화한 경우에만 `CoUninitialize()` 한다.
- `IMMDeviceEnumerator` + `EnumAudioEndpoints(eRender|eCapture, DEVICE_STATE_ACTIVE)`.
- `PKEY_Device_FriendlyName`(PROPVARIANT VT_LPWSTR) → UTF-8 `name`.
- `PKEY_Device_EnumeratorName`이 `BTHENUM`/`BTHHFENUM`이면 `formFactor`에 `Bluetooth`를 넣는다.
  그 외에는 `PKEY_AudioEndpoint_FormFactor`(Speakers/Headphones/... 열거형)을 문자열로 넣는다.
- `PKEY_Device_ContainerId`를 GUID 문자열로 → `containerId`. 같은 물리 장치의 입출력이 같은 값을 갖는다.
- `id`는 `IMMDevice::GetId()`의 `LPWSTR`을 UTF-8로 변환한 값.
- `isDefault`: `GetDefaultAudioEndpoint(flow, eConsole)`의 id와 같으면 true. 실패해도 다른 항목은 계속 채운다.
- `loopbackCapable`: `flow == render`일 때만 true.
- `mixChannels`/`mixSampleRate`/`mixBitsPerSample`: `IAudioClient::GetMixFormat`의
  `WAVEFORMATEX`(또는 `WAVEFORMATEXTENSIBLE`) 값. `GetMixFormat` 실패 시 0으로 두고 계속 진행한다
  (장치 하나의 실패가 전체 열거를 막지 않는다).
- 실패 시 `error`에 사람이 읽을 수 있는 메시지를 넣고 빈 벡터를 반환한다. 성공 시 `error`는 비운다.
- 정렬: 기본 장치를 먼저, 그 다음 이름 오름차순(대소문자 무시).

## 3. 캡처 (`WasapiCapture`)

`open(options, error)`:

- `options.deviceId`가 비면 해당 flow의 기본 엔드포인트(eConsole)를 쓴다.
- `IMMDeviceActivator`로 `IAudioClient` 활성화. **`CLSID_MMDeviceEnumerator`는 사용하지 않는다**.
- `GetMixFormat`으로 공유 모드 포맷을 얻는다. **`Initialize`에 전달하는 포맷은 반드시 `GetMixFormat`이
  준 포맷의 복사본**이어야 한다(AUDCLNT_E_UNSUPPORTED_FORMAT 회피).
- `Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK(해당 시) | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
  hnsBufferDuration, 0, format, nullptr)`. 공유 모드에서 periodicity는 반드시 0.
  `hnsBufferDuration = bufferMs * 10000` (REFERENCE_TIME, 100ns 단위).
- `AUDCLNT_STREAMFLAGS_LOOPBACK`은 **render 엔드포인트에만** 유효하다. `flow == capture`이면
  loopback 플래그를 넣지 않는다. `options.loopback`이 true인데 flow가 render인 경우에만 넣는다.
- 이벤트 콜백: `SetEventHandle(CreateEventW(nullptr, FALSE, FALSE, nullptr))`.
- `IAudioCaptureClient::GetBuffer`로 패킷을 얻는다. `AUDCLNT_BUFFERFLAGS_SILENT`이면 **버퍼를 읽지 않고
  0으로 채운다**(Windows가 데이터 없이 무음을 알리는 정상 경로).
- `AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY`이면 `isDiscontinuity()`가 true가 되도록 기록한다.
- `GetBuffer`가 `AUDCLNT_S_BUFFER_EMPTY`(S_FALSE)를 반환하면 패킷이 없다는 뜻이므로,
  acquire()는 이벤트를 다시 기다린다(에러로 처리하지 않는다).
- `GetMixFormat`이 준 포맷을 **deinterleaved stereo float로 변환**한다:
  - `WAVE_FORMAT_IEEE_FLOAT` 32bit → 그대로
  - `WAVE_FORMAT_PCM` 16bit → `sample / 32768.0f`
  - `WAVE_FORMAT_PCM` 24bit(컨테이너 32bit, 유효 24bit) → 상위 24비트를 부호 있는 값으로 만든 뒤 `8388608.0f`로 나눈다
  - `WAVE_FORMAT_PCM` 32bit → `sample / 2147483648.0f`
  - `WAVE_FORMAT_EXTENSIBLE`이면 `SubFormat`을 보고 위 규칙을 적용한다
  - 채널 수가 1이면 좌우 동일, 2 이상이면 앞 두 채널을 쓴다(나머지는 무시).
    **loopback에서는 채널 0/1이 프론트 L/R이다.**
  - 비유한 샘플은 0으로 만든다.
- `left()`/`right()`는 **미리 할당한 내부 버퍼**를 가리킨다. `maxBlockFrames`(8192)를 넘는 패킷은
  나눠서 처리하지 말고, 초과분을 버리고 `frameCount()`를 8192로 제한한다(문서화할 것).
- `release()`는 `IAudioCaptureClient::ReleaseBuffer(packetFrames, 0)`를 호출한다. 여기서
  `packetFrames`는 **`GetBuffer`가 보고한 전체 패킷 크기**이며, `frameCount()`가 8192로 제한한
  값이 **아니다**. `ReleaseBuffer`는 `NumFramesRead`가 패킷 크기이거나 0이어야 하고 그 밖의 값은
  `AUDCLNT_E_INVALID_SIZE`로 거부하기 때문이다. 획득하지 않았으면 아무것도 하지 않는다.
  - 실측 근거: `--buffer-ms 250`/`500`으로 입력 장치를 열면 협상 주기가 **12000/24000 프레임**으로
    `maxBlockFrames`(8192)를 훨씬 넘는데도 5초 실행이 프레임 손실 없이(240,000) 종료 코드 0으로
    끝난다. 제한된 값을 넘겼다면 `ReleaseBuffer`가 거부해 실패했을 것이다.
- `close()`는 `Stop()` → `Reset()` 순서로 정지한 뒤 COM 객체를 해제한다. 여러 번 호출해도 안전해야 한다.
- `requestStop`에 해당하는 개념: close()가 다른 스레드의 `acquire()`를 깨워야 한다.
  이벤트 핸들에 `SetEvent`를 호출하고, `acquire()`는 `closing_` 플래그를 확인해 false를 반환한다.

## 4. 렌더 (`WasapiRender`)

`open(options, error)`:

- render 엔드포인트 활성화 + `GetMixFormat` + `Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, hnsBufferDuration, 0, format, nullptr)`.
- `IAudioRenderClient`를 얻고, 시작 전에 **버퍼 전체를 무음으로 채운다**(`GetBufferSize` + `GetBuffer` + `ReleaseBuffer(..., AUDCLNT_BUFFERFLAGS_SILENT)`).
- `write()`는 `IAudioRenderClient::GetBuffer(available, &data)`로 공간을 얻고, float stereo를 엔드포인트
  포맷으로 변환해 쓴다(`AUDCLNT_BUFFERFLAGS_SILENT`를 쓰지 말고 실제 샘플을 채운다).
  - float32: 그대로. 16bit: `clamp(x,-1,1) * 32767`. 24bit: `* 8388607`. 32bit PCM: `* 2147483647`.
  - `channels > 2`면 앞 두 채널에 L/R을 넣고 나머지는 0으로 채운다. `channels == 1`이면 `(L+R)*0.5`.
- `periodMs()`: `GetDevicePeriod` 또는 `GetBufferSize / sampleRate`로 계산한 실제 주기를 ms로.
  이때 나누는 값은 **스트림 rate**(요청한 rate)이며 mix rate가 아니다. mix rate로 나누면 보고값이 틀린다.
- `requestStop()`은 원자 플래그를 세우고 이벤트를 `SetEvent`해 대기 중인 `write()`를 깨운다.
- `write()`는 데이터가 부족하면 짧게 대기(`WaitForSingleObject(event, timeoutMs)`)하며 재시도하고,
  stop 요청 시 false를 반환한다. **바쁜 루프(busy-spin)로 CPU를 태우지 않는다.**

### 4-1. 렌더 rate 변환 (AUTOCONVERTPCM)

`WasapiRender::Options::requestedSampleRate`가 0이 아니고 엔드포인트의 mix rate와 다르면,
`Initialize`에 `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY`를
추가하고 `GetMixFormat` 복사본의 `nSamplesPerSec`/`nAvgBytesPerSec`를 요청 rate로 바꾼다.

Microsoft 문서 근거:

> "**AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM** — A channel matrixer and a sample rate converter are
> inserted as necessary to convert between the uncompressed format supplied to
> `IAudioClient::Initialize` and the audio engine mix format."
> "**AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY** — When used with `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`,
> a sample rate converter with better quality than the default conversion but with a higher
> performance cost is used. This should be used if the audio is ultimately intended to be heard by
> humans as opposed to other scenarios such as pumping silence or populating a meter."
> — [AUDCLNT_STREAMFLAGS_XXX Constants](https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants)

이 방식이 DSP 품질을 떨어뜨리지 않는 이유:

1. **DSP는 캡처 장치의 실제 rate에서 실행된다.** 엔진은 캡처 rate로 DSP를 준비하고, 렌더 스트림에
   같은 rate를 요청한다. 계수 생성도 그 rate를 기준으로 한다.
2. **캡처 측은 변환하지 않는다.** loopback/입력이 보는 신호는 장치의 원본 샘플이다.
3. **변환은 렌더 핸드오프에서 한 번만** 일어나며, 손으로 만든 리샘플러가 아니라 Microsoft가
   문서화한 컨버터가 수행한다. `SRC_DEFAULT_QUALITY`는 사람이 듣는 출력이므로 품질을 우선한다.

요청 rate가 mix rate와 같으면 플래그를 추가하지 않는다(불필요한 SRC 방지).

`format()`은 **스트림 rate**(요청한 값)를 보고한다. 그래야 엔진이 캡처 rate와 일치한다고 판단하고
DSP를 그 rate로 준비할 수 있다. 엔진은 open 이후에도 두 rate가 같은지 다시 확인하며, 다르면
(즉 오디오 엔진이 요청을 이행하지 않았으면) 피치가 틀어진 채로 재생하는 대신 실패한다.

## 5. 오류 처리 원칙

### 5-1. COM apartment 수명 (반드시 지킬 것)

`WasapiCapture::Impl`과 `WasapiRender::Impl`은 `ComScope`를 **첫 멤버**로 갖습니다. 이는
"apartment가 인터페이스 포인터보다 오래 살아야 한다"는 규칙을 소멸 순서로 강제하기 위한 것입니다.

C++는 멤버를 선언 역순으로 파괴하므로, 첫 멤버인 `ComScope`가 **가장 마지막**에
`CoUninitialize()`를 호출합니다. `enum`/`device`/`client` 같은 `ComPtr`들은 그보다 먼저
해제되므로, 참조 카운트가 0이 되는 시점에도 apartment가 살아 있습니다.

이 순서를 지키지 않으면(예: `open()` 안의 지역 `ComScope`) `open()`이 반환될 때 apartment가
먼저 사라지고, 나중에 `ComPtr`이 해제될 때 **이미 해체된 apartment의 해제 루틴**을 호출해
접근 위반으로 죽습니다. 두 front end가 각자의 `main()`에서 COM을 초기화하기 때문에 카운트가
0이 되지 않아 오랫동안 드러나지 않았습니다 — 즉 "COM을 초기화해야 한다"는 문서만 따르고
스스로 초기화하지 않는 호출자는 정상 오류 대신 크래시를 만났습니다.

### 5-2. 복구 루프 구조

캡처와 렌더 루프는 같은 형태입니다: **판단은 `nextLoopStep()`이 하고 루프는 그 결과를 수행**합니다.
판단이 `RecoveryPolicy.h`에 있으므로 장치 없이 검사할 수 있고, 엔진이 실제로 따르는 로직과
검사 대상이 갈라지지 않습니다.

```text
nextLoopStep(open, lost, attempted):
  lost == fatal              -> stop        (엔드포인트가 닫혀 있어도 중지)
  !open                      -> attempted >= budget ? stop : attemptOpen
  lost == none               -> run
  lost == deviceLost         -> attempted >= budget ? stop : attemptOpen
```

`attempted`는 열기 시도 횟수이고, 열기에 성공하면 0으로 돌아갑니다. `lost`는 직전 작업의
실패이며, 한 번 읽고 지우므로 오래된 원인이 다음 판단에 영향을 주지 않습니다.

두 가지가 이 순서에서 나옵니다:

- **닫힌 엔드포인트를 먼저 다시 엽니다.** 닫힌 객체에 `acquire()`/`write()`를 호출하는 것은
  장치 상태가 아니라 호출자 오류이므로, 재개방이 실패했을 때 그 경로로 빠지면 첫 재시도에서
  스트림이 끝납니다.
- **복구 불가 실패는 닫힌 상태에서도 중지합니다.** 재개방 자체가 실패하면 엔드포인트는 닫힌 채로
  남는데, "닫혔으니 재시도"로 처리하면 같은 실패에 예산을 전부 씁니다.

### 5-3. 실패 분류

`classifyFailure`가 HRESULT를 세 종류로 나눕니다:

- `deviceLost`: 장치가 지금 없거나 무효 — **재개방으로 복구 가능**
  - `AUDCLNT_E_DEVICE_INVALIDATED`, `AUDCLNT_E_RESOURCES_INVALIDATED`,
    `AUDCLNT_E_ENDPOINT_CREATE_FAILED`, `AUDCLNT_E_SERVICE_NOT_RUNNING`
  - `HRESULT_FROM_WIN32(ERROR_NOT_FOUND)` (0x80070490) — **`IMMDeviceEnumerator::GetDevice`가
    제거된 엔드포인트에 대해 돌려주는 코드**입니다. 이 코드를 fatal로 분류하면 장치가 돌아오기를
    기다리는 재시도 예산이 전혀 쓰이지 않습니다.
- `fatal`: 요청/포맷/환경이 잘못됨 — 재시도해도 같음
  - `AUDCLNT_E_UNSUPPORTED_FORMAT`, `AUDCLNT_E_BUFFER_SIZE_ERROR`, `E_INVALIDARG`,
    `E_POINTER`, `E_OUTOFMEMORY`
  - `AUDCLNT_E_DEVICE_IN_USE`(0x8889000A): 다른 앱이 독점 모드로 점유 중. 장치 문제가 아니라
    구성 충돌이므로 재시도하지 않습니다.
- 알 수 없는 코드는 `fatal`. 모르는 코드를 복구 가능으로 보면 재개방 루프가 코어를 태우고
  장치를 계속 점유합니다.

## 6. 오류 처리 원칙

- 모든 HRESULT는 실패 시 `error`에 `HRESULT` 값(16진수)과 짧은 설명을 넣는다.
- 장치가 사라진 경우(`AUDCLNT_E_DEVICE_INVALIDATED`)는 `error`에 명시적으로 표시할 수 있어야 한다.
  엔진은 이 경우 캡처/렌더를 재시도한다.
- COM 포인터는 `Microsoft::WRL::ComPtr`(WRL)를 사용한다. `<wrl/client.h>`는 SDK에 있다.

## 7. 참고 심볼

`mmdeviceapi.h`: `IMMDeviceEnumerator`, `IMMDevice`, `IMMDeviceCollection`, `CLSID_MMDeviceEnumerator`,
`IID_IMMDeviceEnumerator`, `eRender`, `eCapture`, `eConsole`, `DEVICE_STATE_ACTIVE`, `PKEY_Device_FriendlyName`,
`PKEY_Device_ContainerId`, `PKEY_AudioEndpoint_FormFactor`, `PKEY_Device_EnumeratorName`.
`audioclient.h`: `IAudioClient`, `IAudioCaptureClient`, `IAudioRenderClient`, `AUDCLNT_SHAREMODE_SHARED`,
`AUDCLNT_STREAMFLAGS_EVENTCALLBACK`, `AUDCLNT_STREAMFLAGS_LOOPBACK`, `AUDCLNT_BUFFERFLAGS_SILENT`,
`AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY`, `AUDCLNT_S_BUFFER_EMPTY`, `AUDCLNT_E_DEVICE_INVALIDATED`.
`functiondiscoverykeys_devpkey.h`: `PKEY_Device_FriendlyName` 등.
`mmreg.h`/`ksmedia.h`: `WAVE_FORMAT_IEEE_FLOAT`, `WAVE_FORMAT_EXTENSIBLE`, `KSDATAFORMAT_SUBTYPE_IEEE_FLOAT`,
`KSDATAFORMAT_SUBTYPE_PCM`.
`functiondiscoveryapi.h`: `MFGetAttributeString`은 쓰지 않는다(PKEY/PropVariant 사용).

링크 라이브러리: `ole32`, `uuid`, `avrt`, `propsys` (`Windows/CMakeLists.txt`에 이미 있음).
