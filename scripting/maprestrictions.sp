#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <sourcecolors>
#include <intmap>

public Plugin myinfo =
{
    name = "Map Restrictions",
    author = "Ilusion9",
    description = "Restrict zones if there are fewer CTs than their accepted limit.",
    version = "1.0",
    url = "https://github.com/Ilusion9/"
};

#define EF_NODRAW        32

#define ZONE_SPAWNED              (1 << 0)
#define ZONE_RENDER_ALL           (1 << 1)
#define ZONE_RENDER_TOP           (1 << 2)
#define ZONE_RENDER_BOTTOM        (1 << 3)
#define ZONE_RENDER_FRONT         (1 << 4)
#define ZONE_RENDER_BACK          (1 << 5)
#define ZONE_RENDER_LEFT          (1 << 6)
#define ZONE_RENDER_RIGHT         (1 << 7)

#define TIMER_THINK_INTERVAL        1.0

enum struct ZoneInfo
{
	int flags;
	float pointMin[3];
	float pointMax[3];
}

enum struct RestrictInfo
{
	int limit;
	int rangeStart;
	int rangeEnd;
	char name[256];
}

int g_BeamModel;

ConVar g_Cvar_FreezeTime;
ConVar g_Cvar_HintAlert;

ArrayList g_List_Zones;
ArrayList g_List_Restrictions;

IntMap g_Map_Zones;

Handle g_Timer_FreezeEnd;
Handle g_Timer_RenderZones;

public void OnPluginStart() 
{
	LoadTranslations("maprestrictions.phrases");
	
	g_List_Zones = new ArrayList(sizeof(ZoneInfo));
	g_List_Restrictions = new ArrayList(sizeof(RestrictInfo));
	
	g_Map_Zones = new IntMap();
	
	HookEvent("round_start", Event_RoundStart);
	
	g_Cvar_FreezeTime = FindConVar("mp_freezetime");
	g_Cvar_FreezeTime.AddChangeHook(ConVarChange_FreezeTime);
	
	g_Cvar_HintAlert = CreateConVar("sm_maprestrictions_touch_alert", "1", "Alert players when they touch a restricted zone?", FCVAR_NONE, true, 0.0);
	AutoExecConfig(true, "maprestrictions");
}

public void OnMapStart()
{
	PrecacheModel("models/error.mdl");
	g_BeamModel = PrecacheModel("sprites/laserbeam.vmt");
}

public void OnConfigsExecuted()
{
	char path[PLATFORM_MAX_PATH];
	KeyValues kv = new KeyValues("Map Config");
	
	GetCurrentMap(path, sizeof(path));
	BuildPath(Path_SM, path, sizeof(path), "configs/maprestrictions/%s.cfg", path);
	
	if (kv.ImportFromFile(path))
	{
		if (kv.JumpToKey("Restrictions"))
		{
			if (kv.GotoFirstSubKey(false))
			{
				do
				{
					RestrictInfo restrictInfo;
					restrictInfo.limit = kv.GetNum("limit");
					restrictInfo.rangeStart = g_List_Zones.Length;
					kv.GetString("name", restrictInfo.name, sizeof(RestrictInfo::name));
					
					if (kv.JumpToKey("zones"))
					{
						if (kv.GotoFirstSubKey(false))
						{
							do
							{
								float pointMin[3];
								float pointMax[3];
								ZoneInfo zoneInfo;
								
								kv.GetVector("point_a", pointMin);
								kv.GetVector("point_b", pointMax);
								
								for (int i = 0; i < 3; i++)
								{
									zoneInfo.pointMin[i] = pointMax[i] > pointMin[i] ? pointMin[i] : pointMax[i];
									zoneInfo.pointMax[i] = pointMax[i] > pointMin[i] ? pointMax[i] : pointMin[i];
								}
								
								if (kv.GetNum("render_all"))
								{
									zoneInfo.flags |= ZONE_RENDER_ALL;
								}
								
								if (kv.GetNum("render_top"))
								{
									zoneInfo.flags |= ZONE_RENDER_TOP;
								}
								
								if (kv.GetNum("render_bottom"))
								{
									zoneInfo.flags |= ZONE_RENDER_BOTTOM;
								}
								
								if (kv.GetNum("render_front"))
								{
									zoneInfo.flags |= ZONE_RENDER_FRONT;
								}
								
								if (kv.GetNum("render_back"))
								{
									zoneInfo.flags |= ZONE_RENDER_BACK;
								}
								
								if (kv.GetNum("render_left"))
								{
									zoneInfo.flags |= ZONE_RENDER_LEFT;
								}
								
								if (kv.GetNum("render_right"))
								{
									zoneInfo.flags |= ZONE_RENDER_RIGHT;
								}
								
								g_List_Zones.PushArray(zoneInfo);
								
							} while (kv.GotoNextKey(false));
							kv.GoBack();
						}
						
						kv.GoBack();
					}
					
					if (restrictInfo.rangeStart != g_List_Zones.Length)
					{
						restrictInfo.rangeEnd = g_List_Zones.Length;
						g_List_Restrictions.PushArray(restrictInfo);
					}
					
				} while (kv.GotoNextKey(false));
			}
			
			kv.Rewind();
		}
		
		SetConVar("mp_join_grace_time", "0");
	}
	
	delete kv;
}

public void OnMapEnd()
{
	g_List_Zones.Clear();
	g_List_Restrictions.Clear();
	
	g_Map_Zones.Clear();
	
	delete g_Timer_FreezeEnd;
	delete g_Timer_RenderZones;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) 
{
	g_Map_Zones.Clear();
	
	delete g_Timer_FreezeEnd;
	delete g_Timer_RenderZones;
	
	if (IsValveWarmupPeriod())
	{
		return;
	}
	
	ZoneInfo zoneInfo;
	for (int i = 0; i < g_List_Zones.Length; i++)
	{
		g_List_Zones.GetArray(i, zoneInfo);
		zoneInfo.flags &= ~ZONE_SPAWNED;
		g_List_Zones.SetArray(i, zoneInfo);
	}
	
	g_Timer_FreezeEnd = CreateTimer(g_Cvar_FreezeTime.FloatValue, Timer_OnFreezeTimeEnd, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void ConVarChange_FreezeTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (IsValveWarmupPeriod() || !IsFreezeTimePeriod())
	{
		return;
	}
	
	float freezeTime = g_Cvar_FreezeTime.FloatValue - StringToFloat(oldValue);
	SetLowerBound(freezeTime, 0.1);
	
	delete g_Timer_FreezeEnd;
	g_Timer_FreezeEnd = CreateTimer(freezeTime, Timer_OnFreezeTimeEnd, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void SDK_OnZoneTouch_Post(int entity, int other)
{
	if (!g_Cvar_HintAlert.BoolValue || !IsEntityClient(other))
	{
		return;
	}
	
	int index;
	int reference = EntIndexToEntRef_Ex(entity);
	
	if (!g_Map_Zones.GetValue(reference, index))
	{
		return;
	}
	
	RestrictInfo restrictInfo;
	g_List_Restrictions.GetArray(index, restrictInfo);
	
	char buffer[256];
	Format(buffer, sizeof(buffer), "%t", "Map Restriction Warning", restrictInfo.name, restrictInfo.limit);
	
	CRemoveTags(buffer, sizeof(buffer));
	PrintCenterText(other, buffer);
}

public Action Timer_OnFreezeTimeEnd(Handle timer, any data)
{
	bool renderZones;
	int numCT = GetAliveCTsCount();
	
	ZoneInfo zoneInfo;
	RestrictInfo restrictInfo;
	
	for (int i = 0; i < g_List_Restrictions.Length; i++)
	{
		g_List_Restrictions.GetArray(i, restrictInfo);
		if (numCT >= restrictInfo.limit)
		{
			continue;
		}
		
		bool isRestricted;
		for (int j = restrictInfo.rangeStart; j < restrictInfo.rangeEnd; j++)
		{
			g_List_Zones.GetArray(j, zoneInfo);
			
			int entity = CreateSolidEntity(zoneInfo.pointMin, zoneInfo.pointMax);
			if (entity != -1)
			{
				renderZones = true;
				isRestricted = true;
				
				CreateBombResetEntity(zoneInfo.pointMin, zoneInfo.pointMax);
				
				zoneInfo.flags |= ZONE_SPAWNED;
				g_List_Zones.SetArray(j, zoneInfo);
				
				SDKHook(entity, SDKHook_TouchPost, SDK_OnZoneTouch_Post);
				
				int reference = EntIndexToEntRef_Ex(entity);
				g_Map_Zones.SetValue(reference, i);
			}
		}
		
		if (isRestricted)
		{
			CPrintToChatAll("\x04[Map Restrictions]\x01 %t", "Map Restriction Warning", restrictInfo.name, restrictInfo.limit);
		}
	}
	
	if (renderZones)
	{
		RenderZones();
		g_Timer_RenderZones = CreateTimer(TIMER_THINK_INTERVAL, Timer_RenderZones, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	
	g_Timer_FreezeEnd = null;
}

public Action Timer_RenderZones(Handle timer, any data)
{
	RenderZones();
}

void RenderZones()
{
	ZoneInfo zoneInfo;
	for (int i = 0; i < g_List_Zones.Length; i++)
	{
		g_List_Zones.GetArray(i, zoneInfo);
		if (!view_as<bool>(zoneInfo.flags & ZONE_SPAWNED))
		{
			continue;
		}
		
		RenderZoneToAll(zoneInfo.pointMin, zoneInfo.pointMax, g_BeamModel, TIMER_THINK_INTERVAL + 0.1, 2.0, view_as<int>({255, 0, 0, 255}), zoneInfo.flags);
	}
}

void GetMiddleOfAxis(float& vecMins, float& vecMaxs, float& vecOrigin)
{
	float middle = (vecMaxs - vecMins) / 2.0;
	vecOrigin = vecMins + middle;
	
	vecMins = middle;
	if (vecMins > 0.0)
	{
		vecMins *= -1.0;
	}
	
	vecMaxs = middle;
	if (vecMaxs < 0.0)
	{
		vecMaxs *= -1.0;
	}
}

void GetMiddleOfBox(float vecMins[3], float vecMaxs[3], float vecOrigin[3])
{
	GetMiddleOfAxis(vecMins[0], vecMaxs[0], vecOrigin[0]);
	GetMiddleOfAxis(vecMins[1], vecMaxs[1], vecOrigin[1]);
	GetMiddleOfAxis(vecMins[2], vecMaxs[2], vecOrigin[2]);
}

void RenderZoneToAll(float pointMin[3], const float pointMax[3], int model, float time, float width, const int color[4], int flags = ZONE_RENDER_ALL)
{
	float pos1[3];
	pos1 = pointMax;
	pos1[0] = pointMin[0];
	
	float pos2[3];
	pos2 = pointMax;
	pos2[1] = pointMin[1];
	
	float pos3[3];
	pos3 = pointMax;
	pos3[2] = pointMin[2];
	
	float pos4[3];
	pos4 = pointMin;
	pos4[0] = pointMax[0];
	
	float pos5[3];
	pos5 = pointMin;
	pos5[1] = pointMax[1];
	
	float pos6[3];
	pos6 = pointMin;
	pos6[2] = pointMax[2];
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_TOP) 
		|| view_as<bool>(flags & ZONE_RENDER_BACK))
	{
		TE_SetupBeamPoints(pointMax, pos1, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_TOP) 
		|| view_as<bool>(flags & ZONE_RENDER_RIGHT))
	{
		TE_SetupBeamPoints(pointMax, pos2, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_BACK) 
		|| view_as<bool>(flags & ZONE_RENDER_RIGHT))
	{
		TE_SetupBeamPoints(pointMax, pos3, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_TOP) 
		|| view_as<bool>(flags & ZONE_RENDER_LEFT))
	{
		TE_SetupBeamPoints(pos6, pos1, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_TOP) 
		|| view_as<bool>(flags & ZONE_RENDER_FRONT))
	{
		TE_SetupBeamPoints(pos6, pos2, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_FRONT) 
		|| view_as<bool>(flags & ZONE_RENDER_LEFT))
	{
		TE_SetupBeamPoints(pos6, pointMin, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_BOTTOM) 
		|| view_as<bool>(flags & ZONE_RENDER_FRONT))
	{
		TE_SetupBeamPoints(pos4, pointMin, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_BOTTOM) 
		|| view_as<bool>(flags & ZONE_RENDER_LEFT))
	{
		TE_SetupBeamPoints(pos5, pointMin, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_BACK) 
		|| view_as<bool>(flags & ZONE_RENDER_LEFT))
	{
		TE_SetupBeamPoints(pos5, pos1, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_BOTTOM) 
		|| view_as<bool>(flags & ZONE_RENDER_BACK))
	{
		TE_SetupBeamPoints(pos5, pos3, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_BOTTOM) 
		|| view_as<bool>(flags & ZONE_RENDER_RIGHT))
	{
		TE_SetupBeamPoints(pos4, pos3, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
	
	if (view_as<bool>(flags & ZONE_RENDER_ALL) 
		|| view_as<bool>(flags & ZONE_RENDER_FRONT) 
		|| view_as<bool>(flags & ZONE_RENDER_RIGHT))
	{
		TE_SetupBeamPoints(pos4, pos2, model, model, 0, 0, time, width, width, 1, 0.0, color, 0);
		TE_SendToAll();
	}
}

void SetConVar(const char[] name, const char[] value)
{
	ConVar cvar = FindConVar(name);
	if (cvar == null)
	{
		return;
	}
	
	cvar.SetString(value);
}

void SetLowerBound(any& value, any lowerLimit)
{
	if (value < lowerLimit)
	{
		value = lowerLimit;
	}
}

bool IsValveWarmupPeriod()
{
	return view_as<bool>(GameRules_GetProp("m_bWarmupPeriod"));
}

bool IsFreezeTimePeriod()
{
	return view_as<bool>(GameRules_GetProp("m_bFreezePeriod"));
}

bool IsEntityClient(int client)
{
	return (client > 0 && client <= MaxClients);
}

int EntIndexToEntRef_Ex(int entity)
{
	if (entity == -1)
	{
		return INVALID_ENT_REFERENCE;
	}
	
	if (entity < 0 || entity > 4096)
	{
		return entity;
	}
	
	return EntIndexToEntRef(entity);
}

int GetAliveCTsCount()
{
	int numPlayers = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i) || GetClientTeam(i) != CS_TEAM_CT)
		{
			continue;
		}
		
		numPlayers++;
	}
	
	return numPlayers;
}

int CreateSolidEntity(float pointMin[3], float pointMax[3])
{
	int entity = CreateEntityByName("func_wall_toggle");
	if (entity != -1)
	{
		float vecMins[3];
		float vecMaxs[3];
		float vecOrigin[3];
		
		vecMins = pointMin;
		vecMaxs = pointMax;
		
		GetMiddleOfBox(vecMins, vecMaxs, vecOrigin);
		DispatchKeyValueVector(entity, "origin", vecOrigin);
		
		DispatchSpawn(entity);
		ActivateEntity(entity);
		
		SetEntityModel(entity, "models/error.mdl");
		SetEntProp(entity, Prop_Send, "m_nSolidType", 2);
		SetEntProp(entity, Prop_Send, "m_fEffects", EF_NODRAW);
		
		SetEntPropVector(entity, Prop_Data, "m_vecMins", vecMins);
		SetEntPropVector(entity, Prop_Data, "m_vecMaxs", vecMaxs);
	}
	
	return entity;
}

int CreateBombResetEntity(float pointMin[3], float pointMax[3])
{
	int entity = CreateEntityByName("trigger_bomb_reset");
	if (entity != -1)
	{
		float vecMins[3];
		float vecMaxs[3];
		float vecOrigin[3];
		
		vecMins = pointMin;
		vecMaxs = pointMax;
		
		GetMiddleOfBox(vecMins, vecMaxs, vecOrigin);
		DispatchKeyValueVector(entity, "origin", vecOrigin);
		
		DispatchKeyValue(entity, "spawnflags", "4097");
		
		DispatchSpawn(entity);
		ActivateEntity(entity);
		
		SetEntityModel(entity, "models/error.mdl");
		SetEntProp(entity, Prop_Send, "m_nSolidType", 2);
		SetEntProp(entity, Prop_Send, "m_fEffects", EF_NODRAW);
		
		SetEntPropVector(entity, Prop_Data, "m_vecMins", vecMins);
		SetEntPropVector(entity, Prop_Data, "m_vecMaxs", vecMaxs);
	}
	
	return entity;
}