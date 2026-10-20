import { Tabs } from 'expo-router/js-tabs';
import { Text, type ColorValue } from 'react-native';

import { colors } from '@/theme';

const icon = (glyph: string) =>
  function TabIcon({ color }: { color: ColorValue }) {
    return <Text style={{ color, fontSize: 18 }}>{glyph}</Text>;
  };

export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarStyle: { backgroundColor: colors.bg, borderTopColor: colors.border },
        tabBarActiveTintColor: colors.text,
        tabBarInactiveTintColor: colors.textMuted,
      }}>
      <Tabs.Screen name="feed" options={{ title: 'Feed', tabBarIcon: icon('▶') }} />
      <Tabs.Screen name="create" options={{ title: 'Create', tabBarIcon: icon('＋') }} />
      <Tabs.Screen name="profile" options={{ title: 'Profile', tabBarIcon: icon('●') }} />
    </Tabs>
  );
}
