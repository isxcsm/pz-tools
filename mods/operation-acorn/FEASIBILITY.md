# Operation Acorn 구현 가능성 검토 (FEASIBILITY)

근거: 설치된 Build 42(Steam buildid 25485521, `projectzomboid.jar` 2026-09-28)의 `javap -c` 바이트코드, `media\lua`·`media\scripts` 검색, 설치 폴더에 덮어씌워진 PZ Optimize 클래스와의 대조. 게임 안에서 돌려 본 것은 없다. "미검증" 표시는 마지막 통합 인게임 점검에서 확인할 대상이다. 멀티플레이는 정책대로 검증하지 않았고 막는 장치도 넣지 않는다.

## 1. 요약

### 판정별 수

| 판정 | 수 | 뜻 |
| --- | --- | --- |
| easy-lua | 25 | 바닐라 Lua 이벤트와 공개 메서드만으로 된다 |
| api-hook | 28 | 확장 API에 바닐라 최종 계산 지점 훅이 있어야 한다 |
| hard | 3 | 의도대로는 크거나 정적 분석만으로 확신할 수 없다. 대안이 있다 |
| blocked | 0 | 구현이 막힌 항목은 없다 |

모두 56개다. 사용자 규칙("막히지 않으면 설계에 그대로 둔다")에 따라 빠지는 기능은 없다. hard 3개는 의도를 지키는 대안으로 구현 방법을 잠근다(3장).

### 주요 위험

1. **API 원칙과 충돌.** `extension-api.md`의 "Adds to vanilla"(답은 바닐라 이상만)는 특성 효과와 맞지 않는다. 특성 효과는 대부분 비용을 줄이는 쪽(무게, 지구력, 감염, 낙하 피해)이다. 특성 훅을 넣기 전에 원칙을 "그 모드가 선언한 플레이어 단위 배율만 답을 바꾼다"로 다시 써야 한다.
2. **PZ Optimize 덮어쓰기.** `IsoGameCharacter`, `IsoPlayer`, `Stats`, `IsoMovingObject`, `IsoChunk`, `IsoObject`, `AmbientStreamManager` 등이 설치 폴더에서 덮어씌워져 있다. 의미는 같지만 분기 모양과 return 수가 다르다. API 훅이 "모양이 다르면 건너뜀" 규칙이라 효과가 조용히 빠질 수 있다. 훅은 시그니처 기준으로 찾고 모든 return을 처리해야 한다. 모드는 `PZExtAPI.hooks()` 결과를 플레이어에게 보여 준다.
3. **시야 보정과 가려진 좀비 버그를 나눴다 (2026-10-09).** 노드 '시야 보정'은 `LightingJNI.calculateVisionCone`(Java) 반환값에 각도를 더해 그림자와 좀비가 함께 넓어지게 한다. 원뿔 안인데 안 그려지는 좀비는 B42 버그라 특성이 아니라 모드 기본 기능으로 고친다: Zombie Visibility Fix(워크숍 3814073243, wgetJane)처럼 안 보이는 좀비만 골라 선을 긋고 트이면 `setTargetAlpha`로 그린다. 같은 층은 칸보다 정밀한 선, 바로 위·아래 층은 `LosUtil.lineClear`(z0, z1을 따로 받음).
4. **달리기 속도 노드가 줄일 대상이 없을 수 있다.** 옷의 `RunSpeedModifier`가 B42에서 속도에 들어가지 않는다(`calcRunSpeedModByClothing` 호출 0건). 실제로 작동하는 것은 가방 감속과 신발 x0.85뿐이다.
5. **캐릭터 용량과 하드 한도 50.** 설계의 "상한 50"은 `maxWeight` 상한이 아니다. 캐릭터 인벤토리 `ItemContainer.capacity`의 기본값 50이고, `hasRoomFor`가 이 값과 비교해 더 줍지 못하게 막는다. 용량만 올리면 과적 사다리 위쪽이 이 한도 밖으로 밀린다.
6. **물림 버티기.** 게임 오버가 걸린 유일한 항목이다. 실제 물림 경로로 인게임 확인이 필수다.
7. **설계 문구 정정.** `OnFillContainer` 시점, `isAllExplored`, `doRollItem`, `calculateWalkSpeed`, 강화문, 감염 "확률", 열쇠고리 85%는 코드와 다르다. 정정 내용은 3장 끝에 둔다.

## 2. 기능별 표

API 요구 칸의 영역 이름은 4장의 묶음과 같다.

### 정찰

| 기능 | 판정 | 걸 지점 (근거) | API 요구 | 위험 |
| --- | --- | --- | --- | --- |
| 시야 보정 | api-hook | `LightingJNI.calculateVisionCone(IsoGameCharacter)` static float. `LightingJNI`(네이티브로 넘김)와 `VisibilityPolygon2`(그림자 다각형)가 둘 다 이 값을 읽는다 | vision: 반환값 가산 +12/24/36° (바닐라 특성 가산과 같은 자리, 18~180° 자르기 뒤) | 각도와 cone 값 변환(`coneToDegrees`/`degreesToCone`)을 맞춘다. 상한을 둔다 |
| 가려진 좀비 수정 (기본 기능) | api-hook | Zombie Visibility Fix(워크숍 3814073243, wgetJane) 방식: 후보 거르기(이미 보임, 화면 밖, 시야 거리·원뿔 밖, 두 층 이상 차이 제외) → 같은 층은 칸보다 정밀한 선, 바로 위·아래 층은 `LosUtil.lineClear`(z0≠z1) → `setTargetAlpha`. 드러난 좀비는 `IsoPlayer.TestZombieSpotPlayer`를 간격을 두고 | vision: 같은 처리를 Java에서 프레임당 한 번. Lua판은 초기 시험용 | 층을 넘는 판정은 미검증(계단 위·아래 인게임 확인). 그 모드와 같이 켜면 손을 뗀다. 그 모드 코드는 라이선스가 없어 방법만 참고한다 |
| 육감 | easy-lua | `getCell():getZombieList()`를 0.5초마다 거리로 거름. 진짜 무들은 `Moodle.Update` 하드코딩 때문에 불가하므로 자체 위젯 | 없음 (선택: `zombies.near`) | 무들 열과 위치가 겹치지 않게 해야 함. 가상 좀비는 목록에 없음 |
| 경보 읽기 | easy-lua | `BuildingDef.isAlarmed()`, `BaseVehicle.isAlarmed()`, `getWorldMarkers()` | 없음 | 안 불러진 칸에는 마커를 달 수 없음. 마커 정리(`remove`) 필요 |
| 털이 기록 | easy-lua | 용기별 `ItemContainer.isExplored()`를 건물 진입 때 방 순회로 셈. `OnFillContainer`로 갱신. `BuildingDef.isFullyStreamedIn()` | 없음 (선택: 건물 진입/이탈 이벤트) | 진입 감지가 `OnPlayerUpdate` 칸 비교라 성능 규칙과 어긋남. 플레이어가 놓은 용기는 걸러야 함 |
| 알찬 수색 | api-hook | `ItemPickerJava.getActualSpawnChance(...)` 반환. 호출쪽은 `Rand.Next(10000) <` 비교. 시체도 같은 길 | loot: 확률 배율 | 이미 채운 용기에는 소급 안 됨(설계대로) |
| 탄약 수색 | api-hook | `ItemPickerJava.getLootModifierFromType("Ammo")` 반환 | loot: 분류 배율 | 시체는 zombieDensity 덧셈 때문에 체감이 +50%보다 작을 수 있음(미검증) |
| 밤눈 + 야행성 눈 | api-hook | `LightingJNI.getLumaInverted(IsoGameCharacter)`(private static) 반환. `calculateVisionCone`을 native와 Java 다각형이 함께 씀 | vision: 어둠 복원 비율 | 시야 각도만 되돌리고 화면 밝기는 native라 그대로(설계 범위와 맞음). private이라 구조 변경에 약함 |
| 기척 감지 | easy-lua | `isSneaking()` + 좀비 목록 0.5초 + 8~12방향 묶음 표시 | 없음 (선택: `zombies.near`) | 웅크림 토글과 `isSneaking`이 같은지 미검증 |
| 기척 감지 강화 | easy-lua | `Events.OnWorldSound(x,y,z,radius,volume,source)`. source 형(`IsoZombie`/`BaseVehicle`)으로 구분 | 없음 | 핸들러 첫 줄에서 바로 반환해야 함. 집 경보 소리의 source 형은 미검증 |
| 눈썰미 | easy-lua | 우리 아이템 굴림에 배율 | 없음 | 없음 |

### 하중

| 기능 | 판정 | 걸 지점 (근거) | API 요구 | 위험 |
| --- | --- | --- | --- | --- |
| 운반 효율 본체 (자재·무거운 짐·계열 무게) | api-hook | `IsoGameCharacter.getInventoryWeight()` 반환(return 2곳). 아이템 단위 무게에 걸면 가방·상자 용량까지 줄어서 안 됨. 분류는 인스턴스의 `getDisplayCategory()` | carry: 규칙표 + V-D 계산 + 프레임 메모 | `hasRoomFor`가 들어오는 아이템은 실제 무게로 셈(비대칭). 힘 경험치 조건(`XpUpdate.lua:33`)이 늦게 걸림. PZ Optimize판은 분기 모양이 다름 |
| 가구 무게 | api-hook | 같은 훅. 선택자는 `ItemType.MOVEABLE` | carry: 선택자 itemType | 손에 든 경우 장착 계수를 감소분 D에도 곱해야 함 |
| 열쇠 무게 0 | api-hook | 같은 훅. 감싼 컨테이너 태그 `base:keyring`에 배율 0 | carry: 선택자 컨테이너 태그, 배율 0 | 자물쇠(0.3) 포함 여부를 정해야 함 |
| 과적 견디기: 속도·지구력 | hard | HEAVY_LOAD 레벨을 읽는 곳이 10곳 이상(`calculateBaseSpeed`, `updateEndurance` 6곳 등) | overload: `Moodle.Update`·`getPathSpeed`·`handleLandingImpact`의 `getCapacityWeight()` 호출 결과 훅 | 대안은 의미가 다름: 레벨 1의 벌칙은 남음 |
| 과적 견디기: 낙하 피해 가산 | api-hook | `handleLandingImpact` 안 `getCapacityWeight()` 호출 3곳 | overload: 같은 호출 결과 훅 | PZ Optimize판 메서드 해시가 다름 |
| 과적 견디기: 넘어짐 | api-hook | 바닐라의 과적 넘어짐은 담 넘기(`shouldFallAfterVaultOver`)와 등반(`getClimbingFailChanceFloat`)뿐 | 없음 (overload 훅으로 따라옴) | 문구를 "담·창문 넘다 넘어짐/등반 실패"로 구체화 |
| 옮기기 속도 | easy-lua | `ISInventoryTransferAction:new`, `ISWorldObjectContextMenu.grabItemTime`(바닥 줍기, 기준 120)을 `OnGameStart`에서 감쌈 | carry: 읽기 질의 `efficiency(item)` | SOTO와 ETW도 감쌈(순서·곱 쌓임 미검증) |
| 캐릭터 용량 | api-hook | `IsoGameCharacter.getMaxWeight()` 반환 가산. 캐릭터 인벤토리 `getEffectiveCapacity` | capacity: 최대 무게 가산 + 캐릭터 인벤토리 한도 가산 | 하드 한도 50 문제(1장 위험 5) |
| 저장소 용량 | api-hook | `ItemContainer.getEffectiveCapacity(chr)` 반환(return 3곳). 상한 뒤에 곱하므로 상한을 자연히 넘음 | capacity: 용기 배율 | 가방을 포함하면 `InventoryContainer` 한 겹 더 필요 + 달리기 감속 부수효과 |
| 달리기 속도 | api-hook | `calculateBaseSpeed`의 fullSpeedMod. 옷 감속은 바닐라에서 죽어 있음 | move: fullSpeedMod 값 훅 | 효과가 가방 감속과 신발뿐이라 체감이 매우 작을 수 있음 |
| 전투 속도 | api-hook | `calculateCombatSpeed`의 `combatSpeedModifier` 읽기(유일) | move: 필드 읽기 값 훅 | 하한 클램프 0.8 때문에 효과 구간이 좁음 |
| 갑옷 체질 | api-hook | `getClothingDiscomfortModifier()` 반환. 소비처는 `BodyDamage.UpdateDiscomfort` 하나 | body: 반환 배율 | 낮음 |

### 생존

| 기능 | 판정 | 걸 지점 (근거) | API 요구 | 위험 |
| --- | --- | --- | --- | --- |
| 혈청 적응 | easy-lua | 우리 혈청의 부작용을 우리 Lua에서 노드 단계로 분기 | 없음 | `Stats.add`로 쓰면 지구력·감염 훅에 함께 줄어듦. `stats:set`으로 씀 |
| 빠루 따기 | easy-lua | `OnFillWorldObjectContextMenu` + `ISBaseTimedAction` 파생. `IsoDoor:setLocked`, 차 문 `setLocked/setLockBroken`, `addSound` | 없음 | 바닐라에 "강화문"이 없음(`StrongWooden`을 쓰는 곳 0건) |
| 자물쇠 따기 | easy-lua | 같은 지점. `Base.Paperclip`, `Base.Screwdriver` | 없음 | 강화문 정의는 위와 같음 |
| 부위 피로 | api-hook | `IsoGameCharacter.addStiffness(BodyPartType, float)`. 모든 근육 긴장이 여기로 모임 | body: 인자 배율 | 낮음. 운동 뻐근함은 제외(설계대로) |
| 낙법 | api-hook | `DoLand(float)` → `handleLandingImpact`. 피해가 낙하 높이에 선형 | fall: `DoLand` 인자 재매핑 + `handleLandingImpact` 안 `getImpactIsoSpeed` 호출 배율 | 착지 뒤 바로 달리기와 층=1.0z는 미검증. 치명 구간은 건드리지 않음 |
| 수풀 헤치기 | api-hook | `IsoTree.getSlowFactor`, `IsoPlayer.calculateInTreesSpeed`(애니 속도), `damageWhileInTrees` | move: 두 반환 배율 + 긁힘 확률 게이트 | -100%를 맞추려면 인게임 보정 필요. 숲 전력질주 넘어짐은 바닐라 그대로 |
| 장비 아끼기 | api-hook | `IsoGameCharacter.addHole(BloodBodyPartType, boolean)` 진입 | body: 확률 게이트 | 낮음 |
| 감염 저항 | api-hook | 감기 `Thermoregulator.getCatchAColdDelta`, 오염 `Stats.add(POISON,+)`, 시체 `CorpseCount.getCorpseCount` + `BodyDamage.GetBaseCorpseSickness` | stats: 각각 배율 | B42에는 "확률" 굴림이 없고 쌓이는 양이다(문구 정정) |
| 감염 저항 강화 | api-hook | 긁힘·찢김 `BodyPart.generateZombieInfection(int)`. 물림 `BodyPart.SetBitten(boolean)` 직후 플래그 해제 | infection: 확률 게이트 + 물림 방패 + 이벤트 | 게임 오버가 걸림. 실제 물림 경로로 시험 필수 |
| 걷는 속도 | api-hook | `calculateWalkSpeed`는 블렌드 좌표이고 상한이 있어 못 씀. `IsoPlayer.getDeferredMovement(Vector2, boolean)` 반환을 `PlayerMovementState`일 때만 배율 | move: 상태 조건부 이동 배율 | 지구력 이중 부과 여부와 PZ Optimize AnimParallel 영향 미검증 |
| 지구력 소모 (2차) | api-hook | `Stats.add(ENDURANCE, d<0)`(`remove`가 위임). local player의 Stats 인스턴스 비교 | stats: `Stats.add` 배율 | 낮음 |
| 수면 피로 (2차) | api-hook | `getFatiqueMultiplier()`. 호출처는 `updateStats_Awake` 하나 | stats: 반환 배율 | 낮음 |
| 돌파 질주 | easy-lua | `IsoZombie:knockDown`, `stats:remove(ENDURANCE)`, 앞쪽 2~3칸의 `getMovingObjects()` | 없음 (선택: 넘어짐 게이트) | TREES는 상시 효과다(버튼 없음). 전력질주 시작을 싸게 잡을 방법이 필요. `CANT_SPRINT`·숲에서는 꺼짐 |

### 시스템

| 기능 | 판정 | 걸 지점 (근거) | API 요구 | 위험 |
| --- | --- | --- | --- | --- |
| 첫 보급 (헬기) | api-hook | `Helicopter.setTarget`/`changeState`/`deactivate`. Helicopter는 Lua에 노출되지 않음 | heli: 상태 이벤트 | 헬기는 서버/싱글에서 돎. 투하 순간(Hovering)은 미검증 |
| 칸/청크 로드 알림 | easy-lua | 바닐라 `LoadChunk`(청크당 1회, 8x8칸) | 없음 (설계의 API 요구에서 뺌) | `IsoChunk.wx/wy`를 Lua에서 읽을 수 있는지 미검증 |
| 임무 아이템 주입 | easy-lua | `OnFillContainer`. 칸 로드 때 미탐색 용기에서 발생 | 없음 | 열 때가 아님. PZ Optimize가 채우기를 미룸. 리스폰 중복은 임무별 완료 표시로 막음 |
| 설치 용기 허용 규칙 | easy-lua | `setOnlyAcceptCategory`/`setAcceptItemFunction` | 없음 | 저장되지 않으므로 설치 직후와 `LoadChunk`마다 다시 걺 |
| 설치 용기 용량 100 초과 | api-hook | `ItemContainer.getCapacity()` 끝의 min(100/50/1000). 원시 값은 저장됨 | capacity: 상한 해제 | 다른 모드 용기에 영향이 가지 않게 대상 한정 필요 |
| 확장 키트 (가방) | api-hook | 위 + `InventoryContainer.getCapacity/getEffectiveCapacity`의 min(50 - 무게) | capacity: modData 가산 | 툴팁 계산 경로 미검증 |
| 가방 무게 감소 키트 | easy-lua | `InventoryContainer.setWeightReduction`(저장됨) | 없음 | 정수 퍼센트. 착용 때만 적용 |
| 트렁크 키트 | api-hook | `VehiclePart`가 수리·교체·손상 때 원시 용량을 되돌림 | capacity: 차량 modData 가산 | 질량 증가는 바닐라가 처리. PZ Tools 차량 확장과 상호작용 미검증 |
| 엔진 튜닝 키트 | easy-lua | `BaseVehicle.setEngineFeature`(저장됨). `CarController`가 `getEnginePower` 사용 | 없음 | PZ Tools 차량 주행 확장(`control_ForwardNew` 대체)이 power를 읽는지 미검증 |
| 발전기 전력 기계 | api-hook | `IsoGenerator.setSurroundingElectricity`가 `couldBePoweredByGenerator`/`getGeneratorPowerConsumption` 합산 | power: 스프라이트별 소비 + 객체별 부하 배율 | 짐 속 기계는 안 셈. 기존 power 영역과 같은 메서드 |
| 기계 처리 따라잡기 | easy-lua | `EveryTenMinutes`, `getWorldAgeHours`, `LoadChunk` | 없음 | 안 불러진 동안 전기가 있었는지 모름(과대 계상) |
| 밀봉: 들기·열기 차단 | easy-lua | 용기·`IsMoveAble` 없는 밀봉 타일로 교체 | 없음 | 열린 UI 정리와 저장 호환은 미검증 |
| 밀봉 상자 파괴 감지 | easy-lua | `OnObjectAboutToBeRemoved`/`OnTileRemoved`, `OnGridBurnt` | 없음 | 우리 타일이 타는 경로는 미검증 |
| 지도 원 표시 | easy-lua | `getAPIv3()` 마커 `addGridSquareMarker` | 없음 | 저장되지 않으므로 지도 생성 때 다시 붙임 |
| 전용 주파수 | easy-lua | `OnLoadRadioScripts` + `DynamicRadioChannel` | 없음 | 주파수 충돌은 직접 확인 |
| 커스텀 타일 | easy-lua | `mod.info`의 `pack=`, `tiledef=` | 없음 | tiledef 번호 허용 범위 미확인 |
| 스킨드 배낭 모델 | hard | `M_ALICE_Pack.x`는 텍스트 형식. 전용 뼈 `Bip01_BackPack` | 없음 | 메시·남녀·손·바닥·GUID를 모두 손으로 만들어야 해서 깨지기 쉬움 |
| 환각 빛 번짐 | easy-lua | 비차단 전체 화면 ISUI(`setConsumeMouseEvents(false)`) | 없음 | 그라데이션 에셋 필요 |
| 낙하지 곤충 소리 끄기 | hard | 환경음은 FMOD 이벤트 하나(`updateWorldAmbiance`의 `setVolume`) | audio: 거리별 환경음 감쇠(선택) | 곤충만 골라 끌 수 없음 |
| 소음 방출 | easy-lua | Lua 전역 `addSound(obj,x,y,z,r,v)` | 없음 | 낮음 |
| 루트 리스폰 상호작용 | easy-lua | `LootRespawn.respawnInContainer` → `fillContainer` 재호출 → `OnFillContainer` | 없음 | 임무 중복은 막아야 함. 우리 용기는 분포에 없는 종류 + `setExplored(true)` |

## 3. 막히거나 어려운 것

막힌 것은 없다. hard 3개(시야 보정은 해결되어 표에 남겨 둠)와, 막히지는 않았지만 설계 문구대로는 효과가 나지 않는 항목의 방법을 아래처럼 잠근다. 정적 분석으로는 밸런스를 더 판단하기 어려우므로, 나머지 확인은 통합 인게임 점검으로 넘긴다.

### hard 3개 (+ 해결된 시야 보정)

| 기능 | 의도를 지키는 대안 | 권장 (잠금) |
| --- | --- | --- |
| 시야 보정 | (해결됨) 노드는 원뿔 각도 가산으로, 가려진 좀비는 기본 기능으로 나눴다 (2장 표). | **유지(잠금).** |
| 과적 견디기: 속도·지구력 | 비율 압축: 과적일 때만(capW > max) `capW' = max + (capW - max) x (1 - r)`, r = 0.3/0.6. `Moodle.Update`, `IsoPlayer.getPathSpeed`, `handleLandingImpact`의 `getCapacityWeight()` 호출 결과에 같은 변환을 건다. 레벨을 읽는 모든 곳(속도, 지구력, 등반, 방어)이 따라온다. | **대안으로 유지(잠금).** 문구는 "초과 무게를 70% / 40%로 센다"로 쓴다. 레벨 1 벌칙 완화(`calculateBaseSpeed`·`calculateCombatSpeed`·`updateEndurance` 상수)는 인게임 체감이 부족할 때만 추가한다. |
| 스킨드 배낭 모델 | 바닐라 `M/F_ALICE_Pack.x`와 `LHand/RHand .x`를 복사해 새 텍스처만 입힌다(메시 위험 0). 우리 모양으로 바꿀 때는 SkinWeights를 `Bip01_BackPack` 한 뼈로 줄인 메시를 만든다. | **우리 메시를 직접 만드는 것이 목표다(잠금).** 모든 꼭짓점을 `Bip01_BackPack`에 묶는다. 메시 제작이 실패하면 바닐라 ALICE `.x` 복사 + 새 텍스처 교체판을 대안으로 쓴다. 설계의 "척추 뼈"는 `Bip01_BackPack`으로 고친다. |
| 낙하지 곤충 소리 | 곤충만 끄는 것은 FMOD 뱅크 내용을 몰라 사실상 불가하다. 대안 (a): 낙하지 반경 안에서 환경음 전체를 서서히 줄인다(audio 훅). 대안 (b): 시각 단서(말뚝, 젖은 흙)만 둔다. | **대안으로 유지(잠금): 1차는 (b), (a)는 선택 API로 나중에.** LORE 436행은 "낙하지 주변은 환경음이 가라앉는다"로 고쳐 쓴다. |

### 막히지 않았지만 방법을 바꿔 잠그는 것

| 기능 | 문제 | 잠금 |
| --- | --- | --- |
| 달리기 속도 | 옷 감속이 바닐라에서 죽어 있을 가능성이 높다(바이트코드 기준) | fullSpeedMod 훅은 그대로 만든다. 인게임 점검에서 `ISRunningDebugUI`의 Clothing 줄을 확인한다. 죽어 있으면 노드를 "짐 가방 달리기 감속 경감 -30/-60%"(살아 있는 가방 `RunSpeedModifier`)로 재정의한다. 옷 감속을 되살리는 것은 새 벌칙을 만드는 일이라 하지 않는다. |
| 캐릭터 용량 | 하드 한도 50(캐릭터 인벤토리 capacity)이 과적 사다리를 자름 | `getMaxWeight` 가산과 함께 캐릭터 인벤토리 `getEffectiveCapacity`에 `+1.75 x 가산분`을 더한다. 설계의 "상한(기본 50)" 문구는 "줍기 한도"로 고친다. |
| 저장소 용량 | 가방 포함 여부가 불명확 | 가구·상자만으로 잠근다(캐릭터 소유와 바닥 제외, 바닐라 특성 배율과 같은 범위). 가방은 확장 키트가 맡는다. |
| 걷는 속도 | `calculateWalkSpeed` 결과는 상한 있는 블렌드 좌표라 +15%가 안 남 | `getDeferredMovement` 상태 조건부 배율로 잠근다. 문제가 생기면 `AnimNode.getSpeedScale` 경로로 바꾼다. 웅크림·조준 중에도 적용한다(문구 "걷기·달리기 모두"에 포함). |
| 감염 저항 강화 (물림) | Lua 폴링판은 감염 UI가 잠깐 깜박임 | `SetBitten` 직후 API 방패로 잠근다. API 전에 쓸 임시판은 `EveryOneMinute` 폴링으로 한다. |
| 돌파 질주 | TREES는 상시 효과다(지시문의 "능동/단축키"는 틀림). 문·장애물 부수기는 설계에 없음 | 상시 효과로 잠근다. 전력질주 시작 감지는 0.25초 간격 점검으로 하고, 질주 중에만 앞칸 검사 핸들러를 단다. 문 부수기는 넣지 않는다. |
| 육감 | 진짜 무들 행은 훅 3곳이 필요 | 무들 모양 자체 위젯(켜짐/꺼짐)으로 잠근다. |
| 강화문 | 바닐라에 타입이 없음 | 스프라이트 속성 `forceLocked` + 모드 자체 스프라이트 이름 표로 잠근다. |
| 운반 효율 분류 | DESIGN 12장의 "아이템 종류 → 계열 사전 표"는 정렬 모드의 런타임 변경을 놓친다 | 인스턴스의 `displayCategory` 문자열 → 효율 HashMap으로 잠근다. 표는 노드 변경 때만 다시 만든다. |
| 알찬 수색 vs 시체 탄약 | 시체는 zombieDensity 덧셈 때문에 덜 느는 듯함 | `getLootModifierFromType` 훅으로 시작한다. 인게임 체감이 약하면 `getActualSpawnChance` 하나로 합치고 Ammo 캐시 표를 쓴다. |
| 첫 보급 | 헬기 이벤트 API 전에는 시각을 알 수 없음 | API 전에는 Lua 폴링판(헬기 날 창이 지나면 투하)으로 시작한다. API 이벤트가 생기면 실제 헬기 시각에 맞춘다. "헬기 없음 7일째"와 "늦은 도입" 경로는 폴링판 그대로 둔다. |

### 설계 문서 정정 (코드와 다른 문구)

- DESIGN 6장 도감: `OnFillContainer`는 용기를 열 때가 아니라 칸이 처음 불릴 때 미탐색 용기에서 난다. 도감은 "아이템 종류를 처음 손에 넣는 시점"만 기준으로 잠근다. `OnFillContainer`는 임무 주입과 털이 기록에만 쓴다.
- DESIGN 12장: "좌표 등록 칸 로드 알림(API 요구)"을 Lua `LoadChunk` 키 조회로 바꾼다. 무게 표 문구는 위 HashMap 방식으로 바꾼다. 기계 소비 `IsoGenerator.getTotalPowerUsing`은 `IsoObject.getGeneratorPowerConsumption` 훅으로 바꾼다.
- TREES: 알찬 수색 훅은 `doRollItem`이 아니라 `getActualSpawnChance`다. 시야 보정은 각도 문제가 아니라 LOS 문제다. 걷는 속도 훅은 `calculateWalkSpeed`가 아니라 이동량이다. 열쇠고리 85%는 장착했을 때만 맞다. 과적 넘어짐은 담 넘기와 등반이다. 감염 "확률"은 "쌓이는 속도"다.
- 털이 기록: `BuildingDef.isAllExplored`는 쓰지 않는다(방 단위 플래그).

## 4. 확장 API 요구 목록

공통 전제(먼저 해야 함):

- **원칙 개정 (끝남).** "Adds to vanilla"를 "Vanilla unless declared"로 고쳤다 (pz-tools 56fd3ac, 2026-10-09): 모드가 선언한 것만 답을 바꾸고, 늘리든 줄이든 된다. 선언이 없거나 훅이 답하지 못하면 바닐라 답.
- **formulas형 영역.** 이름 붙은 훅 지점마다 모드가 handle로 정한 배율·확률·가산을 Java 원시 필드에 둔다. local player일 때만 적용한다. 호출마다 Lua를 부르지 않고 할당도 없다.
- **훅 방식.** 시그니처 기준으로 찾고 모든 return을 처리한다. 결과는 `hooks()`로 보고한다(PZ Optimize판 대응).

"기존" 칸은 `extension-api.md`에 이미 있는지를 뜻한다.

| 묶음 | 장치 | 바닐라 훅 지점 | 쓰는 기능 | 기존 |
| --- | --- | --- | --- | --- |
| 무게 (carry) | 규칙표(선택자: displayCategory / itemType / 감싼 컨테이너 태그, 나눔꼴 효율 또는 배율 0) + 감소분 D 계산, 프레임 메모 | `IsoGameCharacter.getInventoryWeight()` 반환 | 운반 효율, 계열 무게, 가구 무게, 열쇠 무게 | 없음 (문서 22행에 "carried weight" 계획만) |
| 무게 | 들어오는 아이템 무게에 같은 감소 적용 | `ItemContainer.hasRoomFor` 오버로드 3개(캐릭터 인벤토리) | 운반 효율 | 없음 |
| 무게 | 읽기 질의 `efficiency(item)` | 위 규칙표 | 옮기기 속도 | 없음 |
| 용량 상한 (capacity) | 최대 무게 가산(정수) | `IsoGameCharacter.getMaxWeight()` 반환 | 캐릭터 용량 | 없음 |
| 용량 상한 | 유효 용량 배율/가산(캐릭터 인벤토리 한도 가산 포함, 바닥 제외) | `ItemContainer.getEffectiveCapacity(chr)` 반환 3곳 | 저장소 용량, 캐릭터 용량 | 없음 |
| 용량 상한 | 상한 해제 + 용기/아이템/차량 modData 가산 | `ItemContainer.getCapacity()` 반환(min 100/50/1000) | 납품 상자·보관함 200+, 확장 키트 (가방, 차량 보관함) | 없음 |
| 용량 상한 | 가방 이중 클램프 처리 | `InventoryContainer.getCapacity()/getEffectiveCapacity(chr)` 반환 | 확장 키트 (가방) | 없음 |
| 과적 (overload) | 과적분 압축 `max + (capW-max)(1-r)` | `Moodle.Update`, `IsoPlayer.getPathSpeed`, `handleLandingImpact`(3곳) 안의 `getCapacityWeight()` 호출 결과 | 과적 견디기 3항목 | 없음 |
| 행동 시간 | API 없음(Lua 감싸기) | `ISInventoryTransferAction:new`, `grabItemTime` | 옮기기 속도 | 해당 없음 |
| 이동·장비 벌칙 (move) | fullSpeedMod 감소율 | `calculateBaseSpeed` fullSpeedMod 저장 지점 | 달리기 속도(재정의 시 가방 감속) | 없음 |
| 이동·장비 벌칙 | 필드 읽기 값 변환 | `calculateCombatSpeed`의 `combatSpeedModifier` 읽기 | 전투 속도 | 없음 |
| 이동·장비 벌칙 | 상태 조건부 이동 배율 | `IsoPlayer.getDeferredMovement(Vector2, boolean)` 반환(`PlayerMovementState`일 때) | 걷는 속도, 2차 걷는 속도 | 없음 |
| 이동·장비 벌칙 | 숲 감속/애니 속도 배율, 긁힘 게이트 | `IsoTree.getSlowFactor`, `IsoPlayer.calculateInTreesSpeed`, `damageWhileInTrees` 진입 | 수풀 헤치기 | 없음 |
| 몸 상태 (stats/body) | 음수 ENDURANCE·양수 POISON 배율(Stats 인스턴스 비교) | `Stats.add(CharacterStat, float)` | 지구력 소모, 감염 저항(오염), 돌파 질주 비용 | 없음 |
| 몸 상태 | 반환 배율 | `getFatiqueMultiplier()`, `Thermoregulator.getCatchAColdDelta()`, `getClothingDiscomfortModifier()` | 수면 피로, 감염 저항(감기), 갑옷 체질 | 없음 |
| 몸 상태 | 시체 수 축소 + 시체 병 속도 배율 | `CorpseCount.getCorpseCount` 반환, `BodyDamage.GetBaseCorpseSickness` 반환 | 감염 저항(시체) | 없음 |
| 몸 상태 | 인자 배율 | `IsoGameCharacter.addStiffness(BodyPartType, float)` | 부위 피로 | 없음 |
| 몸 상태 | 확률 게이트(호출 취소) | `IsoGameCharacter.addHole(BloodBodyPartType, boolean)` | 장비 아끼기 | 없음 |
| 감염 (infection) | 확률 게이트 | `BodyPart.generateZombieInfection(int)` 진입 | 감염 저항 강화(긁힘·찢김) | 없음 |
| 감염 | 물림 방패(무장/해제, 후처리로 플래그 해제) + 이벤트 `OnPZExtBiteSurvived` | `BodyPart.SetBitten(boolean)` 반환 직후 | 감염 저항 강화(물림) | 없음 (이벤트 방식은 `OnPZExtNetworkChange`와 같은 형태) |
| 낙하 (fall) | 인자 재매핑(치명 구간 제외) | `IsoGameCharacter.DoLand(float)` | 낙법 | 없음 |
| 낙하 | 호출 결과 배율(sqrt k) | `handleLandingImpact` 안 `FallDamage.getImpactIsoSpeed()` 호출 | 낙법, 2차 낙법 | 없음 (같은 메서드에 과적 훅이 있으므로 한 소유자로) |
| 전리품 (loot) | 확률 배율 | `ItemPickerJava.getActualSpawnChance(...)` 반환 | 알찬 수색 | 없음 |
| 전리품 | 분류 배율("Ammo") | `ItemPickerJava.getLootModifierFromType(String)` 반환 | 탄약 수색 | 없음 |
| 시야·조명 (vision) | 어둠 복원 비율 | `LightingJNI.getLumaInverted(IsoGameCharacter)` 반환 | 밤눈, 야행성 눈 | 없음 |
| 시야·조명 | 원뿔 각도 가산 / 가려진 좀비 선 검사와 표시 (프레임당 한 번, 후보마다 0.1초 간격 재검사, 캐시 없음. 수정 처리는 API가 갖고, 모드가 켜야만 돈다: "선언 없으면 바닐라" 원칙) | `LightingJNI.calculateVisionCone` 반환 / `IsoZombie.setTargetAlpha`, `LosUtil.lineClear`, `IsoGridSquare.testVisionAdjacent` | 시야 보정 / 가려진 좀비 수정 | 없음 |
| 감지 (sensing, 선택) | 공간 질의 `zombies.near(x,y,z,r)` | `IsoCell.getZombieList()` | 육감, 기척 감지 | 없음 (문서 22행 "spatial queries" 계획만) |
| 감지 (선택) | 건물 진입/이탈 이벤트 | 플레이어 칸 변화 + `IsoMetaGrid.getRoomAt` | 털이 기록 | 일부: `buildings.at(x,y,z)`가 있어 키 판정은 가능 |
| 칸/청크 로드 알림 | 요구에서 뺌(Lua `LoadChunk`). 실측 병목이 보이면 좌표 등록 알림을 다시 올림 | `IsoChunk.doLoadGridsquare` 끝 | 상자 제거·생성, 임무 아이템, 낙하지, 허용 규칙 재설정 | 없음 |
| 헬기 (heli) | 상태 이벤트 `OnPZExtHelicopter(상태, 표적, x, y)` + 선택 상태 읽기 | `Helicopter.setTarget` 끝, `changeState`, `deactivate` | 첫 보급 | 없음 (이벤트 방식은 기존과 같음) |
| 발전기 부하 (power) | 스프라이트별 기본 소비 선언, 객체별 부하 배율 | `IsoObject.couldBePoweredByGenerator()` 반환 OR, `getGeneratorPowerConsumption()` 반환 | 분해기, 재단기, 정제기, 목재 절단기, 단말, 모터 부품 | 일부: power 영역이 이미 `IsoGenerator.setSurroundingElectricity`/`updateGenerator`를 훅하고, `buildings.objects`와 망 부하가 같은 두 메서드를 읽는다. 같은 영역에 넣어야 한다(한 소유자). 넣으면 망 부하에도 자동 반영된다 |
| 차량 (vehicle) | 트렁크는 capacity 묶음에서 처리. 엔진은 API 없음 | `getCapacity`(vehiclePart). 대비책으로 `BaseVehicle.getEnginePower` 반환 배율(save 경로 제외) | 트렁크 키트, 엔진 튜닝 키트 | 없음. PZ Tools 차량 주행 확장이 `getEnginePower`를 읽는지 확인 필요 |
| 소리 (audio, 선택) | 등록 좌표 거리별 환경음 감쇠 | `AmbientStreamManager.updateWorldAmbiance`의 `setVolume` | 낙하지 환경음 | 없음 |

이미 있는 것 중 이 모드가 그대로 쓰는 것: `PZExtAPI.client(name)` handle, `hooks()`, `buildings.at`(건물 키), 이벤트 올리는 방식(`OnPZExtNetworkChange`). 무게, 용량, 전리품, 시야, 몸 상태 영역은 아직 하나도 없다.

## 5. 구현 순서 제안

### 지금 API 없이 시작할 수 있는 것

DESIGN 13장의 핵심 순환 순서를 따른다.

1. **핵심 순환:** 도감(인벤토리 진입 기준) → 통신 단말(커스텀 타일, ISUI) → 첫 보급(Lua 폴링판) → 납품 상자(허용 규칙, `LoadChunk` 재설정, 밀봉 타일 교체, 파괴 감지) → 헬기 정산(10분 이벤트, `LoadChunk`로 상자 정리) → 상점과 혈청 → 트리 화면.
2. **Lua만으로 되는 노드:** 육감(자체 위젯), 기척 감지 1·2, 경보 읽기, 털이 기록, 눈썰미, 혈청 적응, 빠루 따기, 자물쇠 따기, 돌파 질주, 옮기기 속도의 "속도 감소" 부분(무게 반영은 `efficiency` 질의 뒤에 붙임), 감염 저항 강화(물림)의 폴링 임시판.
3. **시스템:** 임무 아이템 주입(`OnFillContainer` + `LoadChunk`, 완료 표시), 루트 리스폰 대비, 가방 무게 감소 키트, 엔진 튜닝 키트(차량 확장 확인 뒤), 기계 처리와 따라잡기(전기 판정은 `haveElectricity`, 소비는 API 뒤), 지도 원, 전용 주파수, 환각 오버레이, 소음 방출, 배낭(자체 메시가 목표, 실패하면 텍스처 교체판), 낙하지 시각 단서.
4. **설계 문서 정정:** 3장 끝 항목을 DESIGN, TREES, LORE에 반영한다.

### API 작업을 기다리는 것 (API 쪽 순서)

1. **기반:** 원칙 개정, formulas형 영역(handle별 배율 필드, local player 게이트, 시그니처 기준 다중 return 훅, `hooks()` 보고). 가장 단순한 훅으로 기반을 검증한다: `getClothingDiscomfortModifier`, `addStiffness`, `getFatiqueMultiplier`, `Stats.add` → 갑옷 체질, 부위 피로, 수면 피로, 지구력 소모.
2. **하중 트리(다람쥐 정체성의 중심):** `getInventoryWeight` + `hasRoomFor` + `efficiency` 질의, `getMaxWeight`, `getEffectiveCapacity`, `getCapacity` 상한, `InventoryContainer` 클램프, 과적 압축(호출 결과 훅), fullSpeedMod, `combatSpeedModifier`. 이 단계에서 용기 용량(납품 상자 200+, 보관함, 가방·트렁크 키트)도 함께 풀린다.
3. **정찰과 생존 나머지:** loot 두 훅, `getLumaInverted`, 낙하 두 훅(과적과 같은 메서드 소유), 숲 세 지점, `getDeferredMovement`, 감염 지점들(`getCatchAColdDelta`, `CorpseCount`, `GetBaseCorpseSickness`, `generateZombieInfection`, `addHole`), 물림 방패와 이벤트.
4. **시스템 API:** 헬기 상태 이벤트(그 뒤 첫 보급을 실제 헬기 시각으로 바꿈), power 영역의 기계 소비 훅.
5. **선택:** 시야 보정(원뿔)과 가려진 좀비 수정은 3단계 vision 묶음에서 만든다. 그 밖에 `zombies.near`, 건물 진입 이벤트, 환경음 감쇠. 실측으로 필요할 때만 한다.

### 마지막 통합 인게임 점검에서 볼 것

- 시야 다각형 가림
- 옷 달리기 감속이 죽어 있는지(`ISRunningDebugUI`)
- 낙법 2층 착지 뒤 바로 달리기
- 수풀 -100% 보정
- 걷는 속도와 지구력·AnimParallel
- 실제 좀비 물림에 대한 물림 방패
- 시체 탄약 체감
- 과적 압축 체감
- `hooks()`에 PZ Optimize판 클래스가 모두 applied로 나오는지
- 엔진 튜닝과 PZ Tools 차량 확장
- 우리 타일의 화재 경로
- `IsoChunk.wx/wy`와 `setForceSprint`, `PropertyContainer`의 Lua 노출
