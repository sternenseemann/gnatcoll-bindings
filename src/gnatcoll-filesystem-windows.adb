-----------------------------------------------------------------------
--                          G N A T C O L L                          --
--                                                                   --
--                 Copyright (C) 2006-2009, AdaCore                  --
--                                                                   --
-- GPS is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this program; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with Ada.Characters.Handling; use Ada.Characters.Handling;
with System;

with GNATCOLL.VFS_Utils; use GNATCOLL.VFS_Utils;

package body GNATCOLL.Filesystem.Windows is

   Cygdrive : constant Filesystem_String := "/cygdrive/";
   --  Default Cygwin full path specification

   function Is_Cygdrive (Path : Filesystem_String) return Boolean;
   pragma Inline (Is_Cygdrive);
   --  Returns True if Path is a starting with /cygdrive/<drive>/

   -----------------
   -- Is_Cygdrive --
   -----------------

   function Is_Cygdrive (Path : Filesystem_String) return Boolean is
   begin
      return Path'Length > Cygdrive'Length + 1
        and then Path
          (Path'First .. Path'First + Cygdrive'Length - 1) = Cygdrive
        and then Is_Letter (Path (Path'First + Cygdrive'Length))
        and then Path (Path'First + Cygdrive'Length + 1) = '/';
   end Is_Cygdrive;

   --------------
   -- Is_Local --
   --------------

   function Is_Local (FS : Windows_Filesystem_Record) return Boolean is
      pragma Unreferenced (FS);
   begin
      return True;
   end Is_Local;

   -------------------------
   -- Directory_Separator --
   -------------------------

   function Dir_Sep (FS : Windows_Filesystem_Record) return Character is
      pragma Unreferenced (FS);
   begin
      return '\';
   end Dir_Sep;

   -------------
   -- To_Unix --
   -------------

   function To_Unix
     (FS         : Windows_Filesystem_Record;
      Path       : Filesystem_String;
      Use_Cygwin : Boolean := False) return Filesystem_String
   is
      pragma Unreferenced (FS);
      The_Path : Filesystem_String := Path;
   begin
      if The_Path'Length > 3 and then
        The_Path (The_Path'First .. The_Path'First + 1) = "\\" then
         --  UNC path. Don't touch it
         return The_Path;
      end if;

      for J in The_Path'Range loop
         if The_Path (J) = '\' then
            The_Path (J) := '/';
         end if;
      end loop;

      if Use_Cygwin
        and then The_Path'Length > 3
        and then The_Path (The_Path'First + 1 .. The_Path'First + 2) = ":/"
      then
         return Cygdrive & (To_Upper (The_Path (The_Path'First))) &
            The_Path (The_Path'First + 2 .. The_Path'Last);
      end if;

      return The_Path;
   end To_Unix;

   ---------------
   -- From_Unix --
   ---------------

   function From_Unix
     (FS   : Windows_Filesystem_Record;
      Path : Filesystem_String) return Filesystem_String
   is
      pragma Unreferenced (FS);
      The_Path : Filesystem_String := Path;
   begin
      --  Convert directory separator to native ones

      for J in The_Path'Range loop
         if The_Path (J) = '/' then
            The_Path (J) := '\';
         end if;
      end loop;

      --  If we have a cygwin drive letter, convert it to native windows, note
      --  that the check below is done using the untranslated Path to properly
      --  match Cygdrive.

      if Is_Cygdrive (Path) then
         return To_Upper (The_Path (The_Path'First + Cygdrive'Length))
           & ':'
           & The_Path (The_Path'First + Cygdrive'Length + 1 .. The_Path'Last);
      end if;

      return The_Path;
   end From_Unix;

   ----------------------
   -- Is_Absolute_Path --
   ----------------------

   function Is_Absolute_Path
     (FS   : Windows_Filesystem_Record;
      Path : Filesystem_String) return Boolean
   is
      pragma Unreferenced (FS);
   begin
      return (Path'Length >= 1 and then Path (Path'First) = '\')
        or else (Path'Length >= 3
                 and then Path (Path'First + 1 .. Path'First + 2) = ":\")
        or else Is_Cygdrive (Path);
   end Is_Absolute_Path;

   --------------
   -- Get_Root --
   --------------

   function Get_Root
     (FS   : Windows_Filesystem_Record;
      Path : Filesystem_String) return Filesystem_String
   is
      pragma Unreferenced (FS);
   begin
      if Path'Length >= 3 and then Path (Path'First + 1) = ':' then
         return Path (Path'First .. Path'First + 2);
      else
         return "C:\";
      end if;
   end Get_Root;

   -----------------
   -- Device_Name --
   -----------------

   function Device_Name
     (FS   : Windows_Filesystem_Record;
      Path : Filesystem_String) return Filesystem_String
   is
      pragma Unreferenced (FS);
   begin
      if Path'Length > 2 and then Path (Path'First + 1) = ':' then
         return Path (Path'First .. Path'First);
      end if;

      return "";
   end Device_Name;

   ----------
   -- Path --
   ----------

   function Path
     (FS     : Windows_Filesystem_Record;
      Device : Filesystem_String;
      Dir    : Filesystem_String;
      File   : Filesystem_String) return Filesystem_String
   is
      pragma Unreferenced (FS);
   begin
      if Device'Length = 1 then
         --  This is a drive letter
         return To_Upper (Device (Device'First)) & ":" & Dir & File;

      else
         --  Not a drive letter, let's return it as-is, this probably should
         --  never happen. The Device can have multiple characters on non
         --  Windows OS.
         return Device & ":" & Dir & File;
      end if;
   end Path;

   -----------------------
   -- Is_Case_Sensitive --
   -----------------------

   function Is_Case_Sensitive
     (FS : Windows_Filesystem_Record) return Boolean
   is
      pragma Unreferenced (FS);
   begin
      return False;
   end Is_Case_Sensitive;

   -----------------
   -- Has_Devices --
   -----------------

   function Has_Devices (FS : Windows_Filesystem_Record) return Boolean is
      pragma Unreferenced (FS);
   begin
      return True;
   end Has_Devices;

   ------------------------
   -- Get_Logical_Drives --
   ------------------------

   procedure Get_Logical_Drives
     (FS     : Windows_Filesystem_Record;
      Buffer : in out Filesystem_String;
      Len    :    out Integer)
   is
      pragma Unreferenced (FS);
      function Internal
        (Buffer : System.Address;
         Length : Integer) return Integer;
      pragma Import (C, Internal, "__gnatcoll_get_logical_drive_strings");

   begin
      Len := Internal (Buffer'Address, Buffer'Length);
   end Get_Logical_Drives;

end GNATCOLL.Filesystem.Windows;
